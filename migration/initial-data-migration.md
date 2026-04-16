# Initial Data Migration from Microservices to Assessment

## Overview

Assessment needs to be seeded with existing data from the microservice databases before data sync can keep it current. This is a one-time migration to populate assessment's local copies of companies, sites, positions, users, suppliers (locations), and contacts (people).

## Prerequisites

- Rails console access to source services (authentication, organisation/company)
- Assessment database created with current schema
- Know your organisation UUID (tenant ID) — required for Apartment tenant switching

## Migration Order

Foreign key dependencies require this order:

```
1. parent_accounts   (no dependencies)
2. companies         (depends on parent_accounts)
3. suppliers          (no dependencies, but import before appointments)
4. sites              (depends on companies)
5. positions          (depends on companies)
6. users              (depends on companies)
7. contacts/people    (depends on companies)
```

## Step 1 — Export from Source Services

### From Organisation Service (companies)

```ruby
# In carelever_organisation (or wherever Company is mastered) rails console
Apartment::Tenant.switch('your-org-id') do
  data = Company.all.map do |c|
    c.attributes.slice(
      'id', 'name', 'display_name', 'short_name',
      'for_screen', 'for_monitor', 'for_manage', 'for_comply',
      'screen_tier', 'monitor_tier', 'manage_tier',
      'ch_id', 'discarded_at',
      'created_at', 'updated_at'
    )
  end
  File.write('/tmp/org_companies.json', data.to_json)
  puts "Exported #{data.size} companies"
end
```

### From Organisation Service (locations → suppliers)

```ruby
Apartment::Tenant.switch('your-org-id') do
  data = Location.where(discarded_at: nil).map do |l|
    l.attributes.slice(
      'id', 'name', 'classification', 'street', 'suburb_name',
      'state', 'phone', 'latitude', 'longitude', 'timezone',
      'self_bookable', 'netsuite_location_id', 'ch_id',
      'created_at', 'updated_at'
    )
  end
  File.write('/tmp/org_locations.json', data.to_json)
  puts "Exported #{data.size} locations"
end
```

### From Company Service (sites, positions, people)

```ruby
Apartment::Tenant.switch('your-org-id') do
  # Sites
  sites = Site.kept.map do |s|
    s.attributes.slice(
      'id', 'name', 'company_id', 'ch_id',
      'for_screen', 'for_monitor', 'for_manage',
      'purchase_order_number', 'discarded_at',
      'created_at', 'updated_at'
    )
  end
  File.write('/tmp/company_sites.json', sites.to_json)
  puts "Exported #{sites.size} sites"

  # Positions
  positions = Position.kept.map do |p|
    p.attributes.slice(
      'id', 'title', 'company_id', 'ch_id',
      'for_screen', 'for_monitor', 'for_manage',
      'discarded_at', 'created_at', 'updated_at'
    )
  end
  File.write('/tmp/company_positions.json', positions.to_json)
  puts "Exported #{positions.size} positions"

  # People (employer contacts)
  people = Person.kept.map do |p|
    p.attributes.slice(
      'id', 'first_name', 'last_name', 'email',
      'mobile', 'landline', 'company_id',
      'authentication_user_id',
      'screen_roles', 'monitor_roles', 'manage_roles',
      'discarded_at', 'created_at', 'updated_at'
    )
  end
  File.write('/tmp/company_people.json', people.to_json)
  puts "Exported #{people.size} people"
end
```

### From Authentication Service (users)

```ruby
Apartment::Tenant.switch('your-org-id') do
  data = User.kept.map do |u|
    u.attributes.slice(
      'id', 'email', 'username', 'first_name', 'last_name',
      'classification', 'company_id', 'is_internal',
      'otp_mode', 'mobile_number', 'landline_number',
      'preference', 'options',
      'created_at', 'updated_at'
    )
  end
  File.write('/tmp/auth_users.json', data.to_json)
  puts "Exported #{data.size} users"
end
```

## Step 2 — Create Import Rake Task in Assessment

Create `lib/tasks/data_migration.rake` in the assessment project:

```ruby
namespace :data_migration do
  desc "Import companies from Organisation service export"
  task import_companies: :environment do
    data = JSON.parse(File.read('/tmp/org_companies.json'))
    data.each do |attrs|
      company = Company.find_or_initialize_by(uuid: attrs['id'])
      company.assign_attributes(
        name: attrs['name'],
        code: attrs['name'].parameterize.upcase,
        active: attrs['discarded_at'].nil?,
        screen_active: attrs['for_screen'] || false,
        monitor_active: attrs['for_monitor'] || false,
        tier: attrs['screen_tier']
      )
      company.save!(validate: false)
    end
    puts "Imported #{data.size} companies"
  end

  desc "Import locations as suppliers from Organisation service export"
  task import_suppliers: :environment do
    data = JSON.parse(File.read('/tmp/org_locations.json'))
    data.each do |attrs|
      supplier = Supplier.find_or_initialize_by(uuid: attrs['id'])
      supplier.assign_attributes(
        name: attrs['name'],
        supplier_type: attrs['classification'],
        street_address: attrs['street'],
        town: attrs['suburb_name'],
        state: attrs['state'],
        phone: attrs['phone'],
        latitude: attrs['latitude'],
        longitude: attrs['longitude'],
        self_bookable: attrs['self_bookable'] || false
      )
      supplier.save!(validate: false)
    end
    puts "Imported #{data.size} suppliers"
  end

  desc "Import sites from Company service export"
  task import_sites: :environment do
    data = JSON.parse(File.read('/tmp/company_sites.json'))
    data.each do |attrs|
      company = Company.find_by(uuid: attrs['company_id'])
      next unless company

      site = Site.find_or_initialize_by(uuid: attrs['id'])
      site.assign_attributes(
        name: attrs['name'],
        company_id: company.id,
        active: attrs['discarded_at'].nil?,
        screen_active: attrs['for_screen'] || false,
        monitor_active: attrs['for_monitor'] || false,
        default_purchase_order: attrs['purchase_order_number']
      )
      site.save!(validate: false)
    end
    puts "Imported #{data.size} sites"
  end

  desc "Import positions from Company service export"
  task import_positions: :environment do
    data = JSON.parse(File.read('/tmp/company_positions.json'))
    data.each do |attrs|
      company = Company.find_by(uuid: attrs['company_id'])
      next unless company

      position = Position.find_or_initialize_by(uuid: attrs['id'])
      position.assign_attributes(
        name: attrs['title'],  # Company service uses 'title', assessment uses 'name'
        company_id: company.id,
        active: attrs['discarded_at'].nil?,
        screen_active: attrs['for_screen'] || false,
        monitor_active: attrs['for_monitor'] || false
      )
      position.save!(validate: false)
    end
    puts "Imported #{data.size} positions"
  end

  desc "Import users from Authentication service export"
  task import_users: :environment do
    data = JSON.parse(File.read('/tmp/auth_users.json'))
    data.each do |attrs|
      company = Company.find_by(uuid: attrs['company_id'])

      user = User.find_or_initialize_by(authentication_user_id: attrs['id'])
      user.assign_attributes(
        email: attrs['email'],
        first_name: attrs['first_name'],
        last_name: attrs['last_name'],
        phone: attrs['mobile_number'],
        primary_company_id: company&.id,
        password_digest: 'not_used_auth_service_handles_login'
      )
      user.save!(validate: false)
    end
    puts "Imported #{data.size} users"
  end

  desc "Import people (contacts) from Company service export"
  task import_contacts: :environment do
    data = JSON.parse(File.read('/tmp/company_people.json'))
    data.each do |attrs|
      company = Company.find_by(uuid: attrs['company_id'])
      next unless company

      roles = attrs['screen_roles'] || []
      contact = Contact.find_or_initialize_by(
        owner_type: 'Company',
        owner_id: company.id,
        email: attrs['email']
      )
      contact.assign_attributes(
        first_name: attrs['first_name'],
        last_name: attrs['last_name'],
        phone: attrs['mobile'],
        is_reportee: roles.include?('reportee'),
        is_updatee: roles.include?('updatee'),
        is_ama: roles.include?('ama'),
        is_sse: roles.include?('sse')
      )
      contact.save!(validate: false)
    end
    puts "Imported #{data.size} contacts"
  end

  desc "Run all imports in order"
  task all: [:import_companies, :import_suppliers, :import_sites,
            :import_positions, :import_users, :import_contacts] do
    puts "All imports complete"
  end
end
```

## Step 3 — Run Imports

```bash
# Copy export files to assessment project (or a shared location)
# Then run in order:
rails data_migration:all

# Or individually:
rails data_migration:import_companies
rails data_migration:import_suppliers
rails data_migration:import_sites
rails data_migration:import_positions
rails data_migration:import_users
rails data_migration:import_contacts
```

## Step 4 — Verify

```ruby
# In assessment rails console
puts "Companies: #{Company.count}"
puts "Suppliers: #{Supplier.count}"
puts "Sites: #{Site.count}"
puts "Positions: #{Position.count}"
puts "Users: #{User.count}"
puts "Contacts: #{Contact.count}"

# Spot check UUID bridge columns
Company.where.not(uuid: nil).count
Site.where.not(uuid: nil).count
User.where.not(authentication_user_id: nil).count
```

## Notes

- `save!(validate: false)` is used because some required fields may not be present in the source data (e.g. assessment-specific fields). Review and add defaults as needed.
- `find_or_initialize_by` makes the import idempotent — safe to re-run.
- Company service uses `title` for positions; assessment uses `name` — mapped in the import.
- Organisation `Location` maps to assessment `Supplier` — field names differ.
- Company service `Person` maps to assessment `Contact` (employer contacts, not candidates).
- Users get a placeholder `password_digest` — assessment doesn't handle login, the auth service does.
- After initial migration, the SNS/SQS sync process keeps data current going forward.
