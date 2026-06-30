# Dump the current Assessment catalog to the 4 CSV templates.
#
# Companion to import.rb — writes the SAME columns the importer reads, so the
# round-trip works: export staging -> KINNECT edits/appends -> import back.
#
# WHAT IT WRITES (into OUTPUT_DIR)
#   assessments.csv         <- every ServiceItem(item_type: 'assessment')
#   components.csv           <- every ServiceItem(item_type: 'component')
#   variations.csv           <- every ServiceVariation (assessment_code = parent's code)
#   component_variants.csv   <- every ComponentVariant (component_code = parent's code)
#   links.csv                <- every ServiceBundleItem (codes + variation names, not UUIDs)
#
# carelever_assessment is single-tenant (no Apartment) — a staging console connects
# to the staging DB automatically. Run in the Assessment Rails console:
#
#   ENV["OUTPUT_DIR"] = "/tmp/kinnect"
#   load "/tmp/kinnect/export.rb"      # or paste this whole file
#
# Read-only. Safe to re-run (overwrites the 4 files each time).
#
# ENV
#   OUTPUT_DIR  (required) folder to write the 4 CSVs into (created if missing).

require "csv"
require "fileutils"

module KinnectExport
  module_function

  ASSESSMENT_COLS = %w[
    code name description booking_required booking_type appointment_duration
    pricing_type service_type employee_eligibility self_bookable
    self_bookable_category has_variants requires_doctor_review has_outcome
  ].freeze

  COMPONENT_COLS = %w[
    code name description booking_required booking_type appointment_duration
    requires_doctor_review self_bookable self_bookable_category
  ].freeze

  VARIATION_COLS = %w[
    assessment_code name code sort_order active booking_type employee_eligibility
  ].freeze

  COMPONENT_VARIATION_COLS = %w[
    component_code name code sort_order active description
  ].freeze

  LINK_COLS = %w[
    assessment_code component_code position variation_name component_variant_name
  ].freeze

  def output_dir = ENV.fetch("OUTPUT_DIR")

  def run!
    FileUtils.mkdir_p(output_dir)
    puts "KINNECT export — OUTPUT_DIR=#{output_dir}"

    write_assessments
    write_components
    write_variations
    write_component_variants
    write_links

    puts "Done."
  end

  def path(name) = File.join(output_dir, name)

  def write_assessments
    items = ServiceItem.where(item_type: "assessment").order(:code)
    write_csv("assessments.csv", ASSESSMENT_COLS) do |csv|
      items.each { |i| csv << ASSESSMENT_COLS.map { |c| i.public_send(c) } }
    end
    puts "  assessments.csv: #{items.count}"
  end

  def write_components
    items = ServiceItem.where(item_type: "component").order(:code)
    write_csv("components.csv", COMPONENT_COLS) do |csv|
      items.each { |i| csv << COMPONENT_COLS.map { |c| i.public_send(c) } }
    end
    puts "  components.csv: #{items.count}"
  end

  def write_variations
    variations = ServiceVariation.includes(:service_item).order("service_items.code", :sort_order)
    write_csv("variations.csv", VARIATION_COLS) do |csv|
      variations.each do |v|
        csv << [
          v.service_item&.code, v.name, v.code, v.sort_order, v.active,
          v.booking_type, v.employee_eligibility
        ]
      end
    end
    puts "  variations.csv: #{variations.count}"
  end

  def write_component_variants
    variants = ComponentVariant.includes(:service_item).order("service_items.code", :sort_order)
    write_csv("component_variants.csv", COMPONENT_VARIATION_COLS) do |csv|
      variants.each do |v|
        csv << [ v.service_item&.code, v.name, v.code, v.sort_order, v.active, v.description ]
      end
    end
    puts "  component_variants.csv: #{variants.count}"
  end

  def write_links
    # Resolve UUID FKs back to the codes/names the importer joins on.
    codes       = ServiceItem.pluck(:id, :code).to_h
    variations  = ServiceVariation.pluck(:id, :name).to_h
    comp_variants = ComponentVariant.pluck(:id, :name).to_h

    links = ServiceBundleItem.order(:bundle_id, :position)
    write_csv("links.csv", LINK_COLS) do |csv|
      links.each do |l|
        csv << [
          codes[l.bundle_id], codes[l.component_id], l.position,
          l.service_variation_id && variations[l.service_variation_id],
          l.component_variant_id && comp_variants[l.component_variant_id]
        ]
      end
    end
    puts "  links.csv: #{links.count}"
  end

  def write_csv(name, headers)
    CSV.open(path(name), "w") do |csv|
      csv << headers
      yield csv
    end
  end
end

KinnectExport.run!
