# Merge the generated CSVs into one Excel workbook with a Legend sheet.
#
# Companion to export.rb. After exporting (or filling in) the CSVs, this rolls them
# into a single .xlsx — one sheet per CSV plus a "Legend" sheet that documents the
# allowed values for every enum/boolean column. Handy for sharing with KINNECT.
#
# Uses caxlsx, which is already a carelever_assessment dependency — run it in the
# Assessment Rails console (so the gem is loaded), right after export.rb:
#
#   ENV["OUTPUT_DIR"] = "/tmp/kinnect"
#   load "/tmp/kinnect/export.rb"          # writes the 5 CSVs
#   load "/tmp/kinnect/build_workbook.rb"  # writes kinnect_catalog.xlsx
#
# ENV
#   OUTPUT_DIR    (required) folder holding the CSVs; the .xlsx is written here too.
#   WORKBOOK_NAME (default "kinnect_catalog.xlsx")

require "csv"
require "caxlsx"

module KinnectWorkbook
  module_function

  # Sheet title -> source CSV. Order matches the fill order.
  SHEETS = {
    "Assessments"        => "assessments.csv",
    "Components"         => "components.csv",
    "Variations"         => "variations.csv",
    "Component Variants" => "component_variants.csv",
    "Links"              => "links.csv"
  }.freeze

  # Enum-style columns -> allowed values, shown on the Legend sheet.
  ENUMS = {
    "booking_type"           => %w[requires_booking no_booking_required walk_in_supplier internal],
    "pricing_type"           => %w[fixed hourly],
    "service_type"           => %w[standard cmwhs],
    "employee_eligibility"   => %w[new_employee existing_employee both],
    "self_bookable_category" => %w[medical urine audiometry spirometry pathology functional]
  }.freeze

  BOOLEAN_COLUMNS = %w[
    booking_required self_bookable has_variants requires_doctor_review has_outcome active
  ].freeze

  def output_dir     = ENV.fetch("OUTPUT_DIR")
  def workbook_name  = ENV.fetch("WORKBOOK_NAME", "kinnect_catalog.xlsx")

  def run!
    dest = File.join(output_dir, workbook_name)
    package = Axlsx::Package.new
    wb = package.workbook

    header_style = wb.styles.add_style(b: true, bg_color: "DDDDDD", border: { style: :thin, color: "999999" })
    title_style  = wb.styles.add_style(b: true, sz: 13)
    label_style  = wb.styles.add_style(b: true)

    add_legend(wb, title_style, label_style)

    SHEETS.each do |sheet_name, file|
      path = File.join(output_dir, file)
      unless File.exist?(path)
        puts "  #{file}: not found, skipping sheet"
        next
      end

      rows = CSV.read(path)
      wb.add_worksheet(name: sheet_name) do |sheet|
        if rows.empty?
          sheet.add_row [ "(no data)" ]
        else
          sheet.add_row rows.first, style: header_style
          rows.drop(1).each { |r| sheet.add_row r }
          sheet.auto_filter = "A1:#{Axlsx.col_ref(rows.first.size - 1)}1"
        end
      end
      puts "  #{sheet_name}: #{[ rows.size - 1, 0 ].max} rows"
    end

    package.serialize(dest)
    puts "Wrote #{dest}"
    dest
  end

  def add_legend(wb, title_style, label_style)
    wb.add_worksheet(name: "Legend") do |sheet|
      sheet.add_row [ "KINNECT catalog — column value reference" ], style: title_style
      sheet.add_row []
      sheet.add_row [ "Codes are the join keys", "Never use UUIDs. A code in Links must exactly match the code in Assessments/Components." ]
      sheet.add_row [ "Fill order", "Components → Assessments → Variations → Component Variants → Links" ]
      sheet.add_row []

      sheet.add_row [ "Boolean columns" ], style: label_style
      sheet.add_row [ "Accepted true",  "Yes / true / 1 / y" ]
      sheet.add_row [ "Accepted false", "No / false / 0 / n  (blank = model default)" ]
      sheet.add_row [ "Columns", BOOLEAN_COLUMNS.join(", ") ]
      sheet.add_row []

      sheet.add_row [ "Enum columns", "Allowed values" ], style: label_style
      ENUMS.each { |col, vals| sheet.add_row [ col, vals.join(" / ") ] }
      sheet.add_row []

      sheet.add_row [ "self_bookable_category", "Required only when self_bookable = true" ]
      sheet.add_row [ "variation_name (Links)", "Blank = applies to all variations; else a name from the Variations sheet" ]
      sheet.add_row [ "component_variant_name (Links)", "Blank = none; else a name from the Component Variants sheet (for that component)" ]
      sheet.add_row [ "code (Variations / Component Variants)", "Optional — auto-generated from name if blank" ]

      sheet.column_widths 32, 70
    end
  end
end

KinnectWorkbook.run!
