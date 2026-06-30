# Bulk-create KINNECT Assessments + Components (+ variations + links) from CSV.
#
# One-off loader for the carelever_assessment app. KINNECT has a large catalog of
# assessments and components to stand up; this reads four CSV templates and creates
# the matching ServiceItem / ServiceVariation / ServiceBundleItem rows.
#
# WHAT IT READS  (codes are the join keys — never UUIDs)
#   assessments.csv         -> ServiceItem(item_type: 'assessment', is_bundle: true)
#   components.csv           -> ServiceItem(item_type: 'component')
#   variations.csv           -> ServiceVariation (on the matching assessment)
#   component_variants.csv   -> ComponentVariant (on the matching component)
#   links.csv                -> ServiceBundleItem (assessment <-> component, opt. per variation)
#
# DESIGN
#   * Two passes: pass 1 creates assessments + components + variations; pass 2
#     resolves codes -> records and creates links. So links can reference anything
#     regardless of file order, and may reference items already in the DB.
#   * Idempotent / resumable: find-or-create by code (items), by (assessment, name)
#     (variations), skip existing bundle links. Re-running only fills gaps.
#   * Normalize-and-validate inputs: "Yes"/"true"/"1" -> true; enum values are
#     downcased and spaces/hyphens -> underscores, then validated against the
#     allowed set with a clear error.
#   * Skip-and-report: a bad row is reported (file + row no. + errors) and skipped;
#     the run is NOT aborted. Good rows still load.
#   * DRY_RUN=true wraps everything in a transaction that rolls back — validates
#     every row (incl. DB uniqueness) and reports, but writes nothing.
#
# carelever_assessment is single-tenant (no Apartment) — a staging console connects
# to the staging DB automatically. Run in the Assessment Rails console:
#
#   ENV["CSV_DIR"] = "/tmp/kinnect"   # folder with the 4 CSVs
#   ENV["DRY_RUN"] = "true"           # validate only — write nothing
#   load "/tmp/kinnect/import.rb"     # or paste this whole file
#
#   # clean dry run? re-run for real:
#   ENV["DRY_RUN"] = "false"
#   load "/tmp/kinnect/import.rb"
#
# ENV
#   CSV_DIR   (required) folder holding assessments.csv / components.csv /
#                        variations.csv / links.csv. Missing files are skipped.
#   DRY_RUN   (default "false") "true" -> validate + report, roll back, write nothing.

require "csv"

module KinnectImport
  module_function

  FILES = %w[assessments.csv components.csv variations.csv component_variants.csv links.csv].freeze

  # Allowed enum values (mirror the model enums). Inputs are normalized then checked.
  BOOKING_TYPES    = %w[requires_booking no_booking_required walk_in_supplier internal].freeze
  PRICING_TYPES    = %w[fixed hourly].freeze
  SERVICE_TYPES    = %w[standard cmwhs].freeze
  ELIGIBILITIES    = %w[new_employee existing_employee both].freeze
  BOOKABLE_CATS    = %w[medical urine audiometry spirometry pathology functional].freeze

  def csv_dir  = ENV.fetch("CSV_DIR")
  def dry_run? = ENV.fetch("DRY_RUN", "false") == "true"

  # --- input coercion --------------------------------------------------------

  def blank?(val) = val.nil? || val.to_s.strip.empty?

  # "Yes"/"true"/"1"/"y" -> true; "No"/"false"/"0"/"n" -> false; blank -> nil.
  def bool(val)
    return nil if blank?(val)

    case val.to_s.strip.downcase
    when "true", "yes", "y", "1", "t"  then true
    when "false", "no", "n", "0", "f"  then false
    end
  end

  # Normalize an enum input: downcase, trim, spaces/hyphens -> underscores.
  def enum(val)
    return nil if blank?(val)

    val.to_s.strip.downcase.gsub(/[\s-]+/, "_")
  end

  def int(val)  = blank?(val) ? nil : Integer(val.to_s.strip, exception: false)

  # Assign a normalized enum, or record an error if the value is unrecognized.
  def put_enum(attrs, key, raw, allowed, errs)
    return if blank?(raw)

    v = enum(raw)
    if allowed.include?(v)
      attrs[key] = v
    else
      errs << "#{key}=#{raw.inspect} (allowed: #{allowed.join(', ')})"
    end
  end

  def put_bool(attrs, key, raw)
    b = bool(raw)
    attrs[key] = b unless b.nil?
  end

  def put_int(attrs, key, raw, errs)
    return if blank?(raw)

    i = int(raw)
    if i.nil?
      errs << "#{key}=#{raw.inspect} (must be an integer)"
    else
      attrs[key] = i
    end
  end

  # Case-insensitive row accessor against a CSV::Row (header strings vary in case).
  def cell(row, *names)
    names.each do |n|
      row.headers.each do |h|
        return row[h] if h && h.to_s.strip.casecmp(n).zero?
      end
    end
    nil
  end

  def read_csv(name)
    path = File.join(csv_dir, name)
    return nil unless File.exist?(path)

    CSV.read(path, headers: true)
  end

  # --- driver ----------------------------------------------------------------

  def run!
    puts "KINNECT import — CSV_DIR=#{csv_dir} dry_run=#{dry_run?}"
    @report = Hash.new { |h, k| h[k] = { created: 0, skipped: 0, errors: [] } }

    if dry_run?
      ActiveRecord::Base.transaction do
        import_all
        raise ActiveRecord::Rollback
      end
    else
      import_all
    end

    print_report
  end

  def import_all
    import_items("assessments.csv", item_type: "assessment", is_bundle: true)
    import_items("components.csv",  item_type: "component",  is_bundle: false)
    import_variations
    import_component_variants
    import_links
  end

  # --- assessments + components (shared ServiceItem path) ---------------------

  def import_items(file, item_type:, is_bundle:)
    rows = read_csv(file)
    return puts("  #{file}: not found, skipping") if rows.nil?

    rows.each.with_index(2) do |row, line|
      code = cell(row, "code").to_s.strip
      name = cell(row, "name").to_s.strip
      next if code.empty? && name.empty? # blank line

      err(file, line, "code is required") if code.empty?
      err(file, line, "name is required") if name.empty?
      next if code.empty?

      existing = ServiceItem.find_by(code: code)
      if existing
        @report[file][:skipped] += 1
        next
      end

      attrs = { code: code, name: name, item_type: item_type, is_bundle: is_bundle }
      attrs[:description] = cell(row, "description").to_s.strip.presence
      put_bool(attrs, :booking_required, cell(row, "booking_required"))
      put_int(attrs, :appointment_duration, cell(row, "appointment_duration"), collect(file, line))
      put_enum(attrs, :booking_type, cell(row, "booking_type"), BOOKING_TYPES, collect(file, line))
      put_enum(attrs, :service_type, cell(row, "service_type"), SERVICE_TYPES, collect(file, line))
      put_enum(attrs, :employee_eligibility, cell(row, "employee_eligibility"), ELIGIBILITIES, collect(file, line))
      put_enum(attrs, :self_bookable_category, cell(row, "self_bookable_category"), BOOKABLE_CATS, collect(file, line))
      put_bool(attrs, :self_bookable, cell(row, "self_bookable"))
      put_bool(attrs, :requires_doctor_review, cell(row, "requires_doctor_review"))

      if item_type == "assessment"
        put_enum(attrs, :pricing_type, cell(row, "pricing_type"), PRICING_TYPES, collect(file, line))
        put_bool(attrs, :has_variants, cell(row, "has_variants"))
        put_bool(attrs, :has_outcome, cell(row, "has_outcome"))
      end

      save_row(file, line, ServiceItem.new(attrs))
    end
  end

  # --- variations ------------------------------------------------------------

  def import_variations
    file = "variations.csv"
    rows = read_csv(file)
    return puts("  #{file}: not found, skipping") if rows.nil?

    rows.each.with_index(2) do |row, line|
      acode = cell(row, "assessment_code").to_s.strip
      name  = cell(row, "name").to_s.strip
      next if acode.empty? && name.empty?

      if acode.empty? || name.empty?
        err(file, line, "assessment_code and name are required")
        next
      end

      assessment = ServiceItem.find_by(code: acode, item_type: "assessment")
      unless assessment
        err(file, line, "no assessment with code #{acode.inspect}")
        next
      end

      if ServiceVariation.exists?(service_item_id: assessment.id, name: name)
        @report[file][:skipped] += 1
        next
      end

      attrs = { service_item: assessment, name: name }
      code = cell(row, "code").to_s.strip
      attrs[:code] = code unless code.empty? # else auto-generated from name
      put_int(attrs, :sort_order, cell(row, "sort_order"), collect(file, line))
      put_bool(attrs, :active, cell(row, "active"))
      put_enum(attrs, :employee_eligibility, cell(row, "employee_eligibility"), ELIGIBILITIES, collect(file, line))

      submitted_bt = enum(cell(row, "booking_type"))
      if submitted_bt && !BOOKING_TYPES.include?(submitted_bt)
        err(file, line, "booking_type=#{cell(row, 'booking_type').inspect} (allowed: #{BOOKING_TYPES.join(', ')})")
        next
      end
      # booking_type is NOT NULL — default it from the parent assessment when blank.
      attrs[:booking_type] = ServiceVariation.resolve_booking_type(service_item: assessment, submitted: submitted_bt)

      save_row(file, line, ServiceVariation.new(attrs))
    end
  end

  # --- component variants ----------------------------------------------------

  def import_component_variants
    file = "component_variants.csv"
    rows = read_csv(file)
    return puts("  #{file}: not found, skipping") if rows.nil?

    rows.each.with_index(2) do |row, line|
      ccode = cell(row, "component_code").to_s.strip
      name  = cell(row, "name").to_s.strip
      next if ccode.empty? && name.empty?

      if ccode.empty? || name.empty?
        err(file, line, "component_code and name are required")
        next
      end

      component = ServiceItem.find_by(code: ccode, item_type: "component")
      unless component
        err(file, line, "no component with code #{ccode.inspect}")
        next
      end

      if ComponentVariant.exists?(service_item_id: component.id, name: name)
        @report[file][:skipped] += 1
        next
      end

      attrs = { service_item: component, name: name }
      code = cell(row, "code").to_s.strip
      attrs[:code] = code unless code.empty? # else auto-generated from name
      attrs[:description] = cell(row, "description").to_s.strip.presence
      put_int(attrs, :sort_order, cell(row, "sort_order"), collect(file, line))
      put_bool(attrs, :active, cell(row, "active"))

      save_row(file, line, ComponentVariant.new(attrs))
    end
  end

  # --- links -----------------------------------------------------------------

  def import_links
    file = "links.csv"
    rows = read_csv(file)
    return puts("  #{file}: not found, skipping") if rows.nil?

    rows.each.with_index(2) do |row, line|
      acode = cell(row, "assessment_code").to_s.strip
      ccode = cell(row, "component_code").to_s.strip
      next if acode.empty? && ccode.empty?

      if acode.empty? || ccode.empty?
        err(file, line, "assessment_code and component_code are required")
        next
      end

      bundle    = ServiceItem.find_by(code: acode, item_type: "assessment")
      component = ServiceItem.find_by(code: ccode, item_type: "component")
      (err(file, line, "no assessment with code #{acode.inspect}") unless bundle) ||
        (err(file, line, "no component with code #{ccode.inspect}") unless component)
      next unless bundle && component

      variation = nil
      vname = cell(row, "variation_name").to_s.strip
      unless vname.empty?
        variation = ServiceVariation.find_by(service_item_id: bundle.id, name: vname)
        unless variation
          err(file, line, "assessment #{acode} has no variation named #{vname.inspect}")
          next
        end
      end

      component_variant = nil
      cvname = cell(row, "component_variant_name").to_s.strip
      unless cvname.empty?
        component_variant = ComponentVariant.find_by(service_item_id: component.id, name: cvname)
        unless component_variant
          err(file, line, "component #{ccode} has no variant named #{cvname.inspect}")
          next
        end
      end

      if ServiceBundleItem.exists?(bundle_id: bundle.id, component_id: component.id, service_variation_id: variation&.id)
        @report[file][:skipped] += 1
        next
      end

      attrs = {
        bundle: bundle, component: component,
        service_variation: variation, component_variant: component_variant
      }
      put_int(attrs, :position, cell(row, "position"), collect(file, line))
      save_row(file, line, ServiceBundleItem.new(attrs))
    end
  end

  # --- save + reporting ------------------------------------------------------

  def save_row(file, line, record)
    if record.save
      @report[file][:created] += 1
    else
      err(file, line, record.errors.full_messages.join(", "))
    end
  end

  def err(file, line, msg)  = @report[file][:errors] << "row #{line}: #{msg}"

  # Tiny adapter so put_enum/put_int can append into the per-file error bucket.
  def collect(file, line)
    Collector.new(self, file, line)
  end

  class Collector
    def initialize(ctx, file, line) = (@ctx, @file, @line = ctx, file, line)
    def <<(msg) = @ctx.err(@file, @line, msg)
    def include?(_) = false
  end

  def print_report
    puts dry_run? ? "\n=== DRY RUN (nothing written) ===" : "\n=== RESULT ==="
    FILES.each do |f|
      r = @report[f]
      next if r[:created].zero? && r[:skipped].zero? && r[:errors].empty?

      puts "#{f}: #{r[:created]} created, #{r[:skipped]} skipped, #{r[:errors].size} errors"
      r[:errors].first(50).each { |e| puts "    - #{e}" }
      puts "    … #{r[:errors].size - 50} more" if r[:errors].size > 50
    end
    total_err = FILES.sum { |f| @report[f][:errors].size }
    puts dry_run? && total_err.zero? ? "\nDry run clean — safe to run with DRY_RUN=false." : ""
    @report
  end
end

KinnectImport.run!
