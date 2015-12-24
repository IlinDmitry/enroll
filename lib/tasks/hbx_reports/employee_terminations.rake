require 'csv'

namespace :reports do
  namespace :shop do

    desc "Employee terminations by employer profile and date range"
    task :employee_terminations => :environment do

      date_range = Date.new(2015,10,1)..TimeKeeper.date_of_record

      census_employees = CensusEmployee.find_all_terminated(date_range: date_range)

      field_names  = %w(
          last_name first_name ssn dob hired_on employment_terminated_on aasm_state employer_name
        )

      processed_count = 0
      file_name = "#{Rails.root}/public/employee_terminations.csv"
      CSV.open(file_name, "w", force_quotes: true) do |csv|
        csv << field_names
        census_employees.each do |census_employee|
          last_name                 = census_employee.last_name
          first_name                = census_employee.first_name
          ssn                       = census_employee.ssn
          dob                       = census_employee.dob
          hired_on                  = census_employee.hired_on
          employment_terminated_on  = census_employee.employment_terminated_on
          aasm_state                = census_employee.aasm_state

          employer_name = census_employee.employer_profile.organization.legal_name

          # csv << field_names.map { |field_name| field_name == "ssn" ? '"' + eval(field_name) + '"' : eval("#{field_name}") }
          csv << field_names.map do |field_name| 
            if field_name == "ssn"
              '="' + eval(field_name) + '"'
            else
              eval("#{field_name}")
            end
          end
          processed_count += 1
        end
      end

      puts "For period #{date_range.first} - #{date_range.last}, #{processed_count} employee terminations output to file: #{file_name}"
    end
  end
end