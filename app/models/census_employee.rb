class CensusEmployee < CensusMember
  include AASM
  include Sortable
  include Searchable
  # include Validations::EmployeeInfo
  include Autocomplete
  include Acapi::Notifiers
  include Config::AcaModelConcern
  include ::Eligibility::CensusEmployee
  include ::Eligibility::EmployeeBenefitPackages
  include Concerns::Observable
  include ModelEvents::CensusEmployee

  require 'roo'

  EMPLOYMENT_ACTIVE_STATES = %w(eligible employee_role_linked employee_termination_pending newly_designated_eligible newly_designated_linked cobra_eligible cobra_linked cobra_termination_pending)
  EMPLOYMENT_TERMINATED_STATES = %w(employment_terminated cobra_terminated rehired)
  EMPLOYMENT_ACTIVE_ONLY = %w(eligible employee_role_linked employee_termination_pending newly_designated_eligible newly_designated_linked)
  NEWLY_DESIGNATED_STATES = %w(newly_designated_eligible newly_designated_linked)
  LINKED_STATES = %w(employee_role_linked newly_designated_linked cobra_linked)
  ELIGIBLE_STATES = %w(eligible newly_designated_eligible cobra_eligible employee_termination_pending cobra_termination_pending)
  COBRA_STATES = %w(cobra_eligible cobra_linked cobra_terminated cobra_termination_pending)
  PENDING_STATES = %w(employee_termination_pending cobra_termination_pending)
  ENROLL_STATUS_STATES = %w(enroll waive will_not_participate)

  EMPLOYEE_TERMINATED_EVENT_NAME = "acapi.info.events.census_employee.terminated"
  EMPLOYEE_COBRA_TERMINATED_EVENT_NAME = "acapi.info.events.census_employee.cobra_terminated"

  field :is_business_owner, type: Boolean, default: false
  field :hired_on, type: Date
  field :employment_terminated_on, type: Date
  field :coverage_terminated_on, type: Date
  field :aasm_state, type: String
  field :expected_selection, type: String, default: "enroll"

  # Employer for this employee
  field :employer_profile_id, type: BSON::ObjectId

  # Employee linked to this roster record
  field :employee_role_id, type: BSON::ObjectId

  field :cobra_begin_date, type: Date

  embeds_many :census_dependents,
    cascade_callbacks: true,
    validate: true

  embeds_many :benefit_group_assignments,
    cascade_callbacks: true,
    validate: true

  embeds_many :workflow_state_transitions, as: :transitional

  accepts_nested_attributes_for :census_dependents, :benefit_group_assignments

  validates_presence_of :employer_profile_id, :ssn, :dob, :hired_on, :is_business_owner
  validate :check_employment_terminated_on
  validate :active_census_employee_is_unique
  validate :allow_id_info_changes_only_in_eligible_state
  validate :check_census_dependents_relationship
  validate :no_duplicate_census_dependent_ssns
  validate :check_cobra_begin_date
  validate :check_hired_on_before_dob
  validates :expected_selection,
    inclusion: {in: ENROLL_STATUS_STATES, message: "%{value} is not a valid  expected selection" }
  after_update :update_hbx_enrollment_effective_on_by_hired_on

  before_save :assign_default_benefit_package
  before_save :allow_nil_ssn_updates_dependents

  index({aasm_state: 1})
  index({last_name: 1})
  index({dob: 1})

  index({encrypted_ssn: 1, dob: 1, aasm_state: 1})
  index({employee_role_id: 1}, {sparse: true})
  index({employer_profile_id: 1, encrypted_ssn: 1, aasm_state: 1})
  index({employer_profile_id: 1, last_name: 1, first_name: 1, hired_on: -1 })
  index({employer_profile_id: 1, hired_on: 1, last_name: 1, first_name: 1 })
  index({employer_profile_id: 1, is_business_owner: 1})

  index({"benefit_group_assignments._id" => 1})
  index({"benefit_group_assignments.benefit_group_id" => 1})
  index({"benefit_group_assignments.aasm_state" => 1})

  scope :active,            ->{ any_in(aasm_state: EMPLOYMENT_ACTIVE_STATES) }
  scope :terminated,        ->{ any_in(aasm_state: EMPLOYMENT_TERMINATED_STATES) }
  scope :non_terminated,    ->{ where(:aasm_state.nin => EMPLOYMENT_TERMINATED_STATES) }
  scope :newly_designated,  ->{ any_in(aasm_state: NEWLY_DESIGNATED_STATES) }
  scope :linked,            ->{ any_in(aasm_state: LINKED_STATES) }
  scope :eligible,          ->{ any_in(aasm_state: ELIGIBLE_STATES) }
  scope :without_cobra,     ->{ not_in(aasm_state: COBRA_STATES) }
  scope :by_cobra,          ->{ any_in(aasm_state: COBRA_STATES) }
  scope :pending,           ->{ any_in(aasm_state: PENDING_STATES) }
  scope :active_alone,      ->{ any_in(aasm_state: EMPLOYMENT_ACTIVE_ONLY) }
  scope :expected_to_enroll,->{ where(expected_selection: 'enroll') }

  # scope :emplyee_profiles_active_cobra,        ->{ where(aasm_state: "eligible") }
  scope :employee_profiles_terminated,         ->{ where(aasm_state: "employment_terminated")}

  #TODO - need to add fix for multiple plan years
  # scope :enrolled,    ->{ where("benefit_group_assignments.aasm_state" => ["coverage_selected", "coverage_waived"]) }
  # scope :covered,     ->{ where( "benefit_group_assignments.aasm_state" => "coverage_selected" ) }
  # scope :waived,      ->{ where( "benefit_group_assignments.aasm_state" => "coverage_waived" ) }

  scope :covered,    ->{ where(:"benefit_group_assignments" => {
    :$elemMatch => { :aasm_state => "coverage_selected", :is_active => true }
    })}

  scope :waived,    ->{ where(:"benefit_group_assignments" => {
    :$elemMatch => { :aasm_state => "coverage_waived", :is_active => true }
    })}

  scope :enrolled, -> { any_of([covered.selector, waived.selector]) }


  scope :employee_name, -> (employee_name) { any_of({first_name: /#{employee_name}/i}, {last_name: /#{employee_name}/i}, first_name: /#{employee_name.split[0]}/i, last_name: /#{employee_name.split[1]}/i) }

  scope :sorted,                -> { order(:"census_employee.last_name".asc, :"census_employee.first_name".asc)}
  scope :order_by_last_name,    -> { order(:"census_employee.last_name".asc) }
  scope :order_by_first_name,   -> { order(:"census_employee.first_name".asc) }

  scope :by_employer_profile_id,          ->(employer_profile_id) { where(employer_profile_id: employer_profile_id) }
  scope :non_business_owner,              ->{ where(is_business_owner: false) }
  scope :by_benefit_group_assignment_ids, ->(benefit_group_assignment_ids) { any_in("benefit_group_assignments._id" => benefit_group_assignment_ids) }
  scope :by_benefit_group_ids,            ->(benefit_group_ids) { any_in("benefit_group_assignments.benefit_group_id" => benefit_group_ids) }
  scope :by_ssn,                          ->(ssn) { where(encrypted_ssn: CensusMember.encrypt_ssn(ssn)) }

  scope :matchable, ->(ssn, dob) {
    matched = unscoped.and(encrypted_ssn: CensusMember.encrypt_ssn(ssn), dob: dob, aasm_state: {"$in": ELIGIBLE_STATES })
    benefit_group_assignment_ids = matched.flat_map() do |ee|
      ee.published_benefit_group_assignment ? ee.published_benefit_group_assignment.id : []
    end
    matched.by_benefit_group_assignment_ids(benefit_group_assignment_ids)
  }

  scope :unclaimed_matchable, ->(ssn, dob) {
   linked_matched = unscoped.and(encrypted_ssn: CensusMember.encrypt_ssn(ssn), dob: dob, aasm_state: {"$in": LINKED_STATES})
   unclaimed_person = Person.where(encrypted_ssn: CensusMember.encrypt_ssn(ssn), dob: dob).detect{|person| person.employee_roles.length>0 && !person.user }
   unclaimed_person ? linked_matched : unscoped.and(id: {:$exists => false})
  }

  def initialize(*args)
    super(*args)
    write_attribute(:employee_relationship, "self")
  end

  def is_linked?
    LINKED_STATES.include?(aasm_state)
  end

  def is_eligible?
    ELIGIBLE_STATES.include?(aasm_state)
  end

  def allow_nil_ssn_updates_dependents
    census_dependents.each do |cd|
      if cd.ssn.blank?
        cd.unset(:encrypted_ssn)
      end
    end
  end

  def update_hbx_enrollment_effective_on_by_hired_on
    if employee_role.present? && hired_on != employee_role.hired_on
      employee_role.set(hired_on: hired_on)
      enrollments = employee_role.person.primary_family.active_household.hbx_enrollments.shop_market.enrolled_and_renewing.open_enrollments rescue []
      enrollments.each do |enrollment|
        if hired_on > enrollment.effective_on
          effective_on = enrollment.benefit_group.effective_on_for(hired_on)
          enrollment.update_current(effective_on: effective_on)
        end
      end
    end
  end

  def suggested_cobra_effective_date
    return nil if self.employment_terminated_on.nil?
    self.employment_terminated_on.next_month.beginning_of_month
  end

  def employer_profile=(new_employer_profile)
    raise ArgumentError.new("expected EmployerProfile") unless new_employer_profile.is_a?(EmployerProfile)
    self.employer_profile_id = new_employer_profile._id
    @employer_profile = new_employer_profile
  end

  def employer_profile
    return @employer_profile if defined? @employer_profile
    @employer_profile = EmployerProfile.find(self.employer_profile_id) unless self.employer_profile_id.blank?
  end

  # This performs employee summary count for waived and enrolled in the latest plan year
  def perform_employer_plan_year_count
    if plan_year = self.employer_profile.latest_plan_year
      plan_year.enrolled_summary = plan_year.total_enrolled_count
      plan_year.waived_summary = plan_year.waived_count
      plan_year.save!
    end
  end

  def employee_role=(new_employee_role)
    raise ArgumentError.new("expected EmployeeRole") unless new_employee_role.is_a? EmployeeRole
    return false unless self.may_link_employee_role?

    # Guard against linking employee roles with different employer/identifying information
    if (self.employer_profile_id == new_employee_role.employer_profile._id)
      self.employee_role_id = new_employee_role._id
      self.link_employee_role
      @employee_role = new_employee_role
      self
    else
      message =  "Identifying information mismatch error linking employee role: "\
                 "#{new_employee_role.inspect} "\
                 "with census employee: #{self.inspect}"
      Rails.logger.error { message }
      #raise CensusEmployeeError, message
    end
  end

  def employee_role
    return @employee_role if defined? @employee_role
    @employee_role = EmployeeRole.find(self.employee_role_id) unless self.employee_role_id.blank?
  end

  def qle_30_day_eligible?
    is_inactive? && (TimeKeeper.date_of_record - employment_terminated_on).to_i < 30
  end

  # Initialize a new, refreshed instance for rehires via deep copy
  def replicate_for_rehire
    return nil unless self.employment_terminated?
    new_employee = self.dup
    new_employee.hired_on = nil
    new_employee.employment_terminated_on = nil
    new_employee.employee_role_id = nil
    new_employee.benefit_group_assignments = []
    new_employee.aasm_state = :eligible
    self.rehire_employee_role

    # new_employee.census_dependents = self.census_dependents unless self.census_dependents.blank?
    new_employee
  end

  def is_business_owner?
    is_business_owner
  end

  def is_covered_or_waived?
    ["coverage_selected", "coverage_waived"].include?(active_benefit_group_assignment.aasm_state)
  end

  def terminate_employment(employment_terminated_on)
    begin
      terminate_employment!(employment_terminated_on)
    rescue => e
      Rails.logger.error { e }
      false
    else
      self
    end
  end

  def terminate_employee_enrollments
    [self.active_benefit_group_assignment, self.renewal_benefit_group_assignment].compact.each do |assignment|
      enrollments = HbxEnrollment.find_enrollments_by_benefit_group_assignment(assignment)
      enrollments.each do |e|
        if e.effective_on > self.coverage_terminated_on
          e.cancel_coverage!(self.employment_terminated_on) if e.may_cancel_coverage?
        else
          if self.coverage_terminated_on < TimeKeeper.date_of_record
            e.terminate_coverage!(self.coverage_terminated_on) if e.may_terminate_coverage?
          else
            e.schedule_coverage_termination!(self.coverage_terminated_on) if e.may_schedule_coverage_termination?
          end
        end
      end
    end
  end

  def terminate_employment!(employment_terminated_on)
    if may_schedule_employee_termination?
      self.employment_terminated_on = employment_terminated_on
      self.coverage_terminated_on = earliest_coverage_termination_on(employment_terminated_on)
    end

    if employment_terminated_on < TimeKeeper.date_of_record
      if may_terminate_employee_role?
        terminate_employee_role!
        # perform_employer_plan_year_count
      else
        message = "Error terminating employment: unable to terminate employee role for: #{self.full_name}"
        Rails.logger.error { message }
        raise CensusEmployeeError, message
      end
    else # Schedule Future Terminations as employment_terminated_on is in the future
      schedule_employee_termination! if may_schedule_employee_termination?
    end

    terminate_employee_enrollments
    self
  end

  def earliest_coverage_termination_on(employment_termination_date, submitted_date = TimeKeeper.date_of_record)

    employment_based_date = employment_termination_date.end_of_month
    submitted_based_date  = TimeKeeper.date_of_record.
                              advance(Settings.
                                          aca.
                                          shop_market.
                                          retroactive_coverage_termination_maximum
                                          .to_hash
                                        ).end_of_month

    # if current_user.has_hbx_staff_role?
    # end

    [employment_based_date, submitted_based_date].max
  end

  def is_active?
    EMPLOYMENT_ACTIVE_STATES.include?(aasm_state)
  end

  def is_inactive?
    EMPLOYMENT_TERMINATED_STATES.include?(aasm_state)
  end

  def active_or_pending_termination?
    return true if self.employment_terminated_on.present?
    return true if PENDING_STATES.include?(self.aasm_state)
    return false if self.rehired?
    !(self.is_eligible? || self.employee_role_linked?)
  end

  def employee_relationship
    "employee"
  end

  def build_from_params(census_employee_params, benefit_group_id)
    self.attributes = census_employee_params

    if benefit_group_id.present?
      benefit_group = BenefitGroup.find(BSON::ObjectId.from_string(benefit_group_id))
      new_benefit_group_assignment = BenefitGroupAssignment.new_from_group_and_census_employee(benefit_group, self)
      self.benefit_group_assignments = new_benefit_group_assignment.to_a
    end
  end

  def send_invite!
    if has_benefit_group_assignment?
      plan_year = active_benefit_group_assignment.benefit_group.plan_year
      if plan_year.employees_are_matchable?
        Invitation.invite_employee_for_open_enrollment!(self)
        return true
      end
    end
    false
  end

  def construct_employee_role_for_match_person
    employee_relationship = Forms::EmployeeCandidate.new({first_name: first_name,
                                                          last_name: last_name,
                                                          ssn: ssn,
                                                          dob: dob.strftime("%Y-%m-%d")})
    person = employee_relationship.match_person if employee_relationship.present?
    return false if person.blank? || (person.present? &&
                                      person.has_active_employee_role_for_census_employee?(self))
    Factories::EnrollmentFactory.build_employee_role(person, nil, employer_profile, self, hired_on)
    return true
  end

  def newhire_enrollment_eligible?
    active_benefit_group_assignment.present? && active_benefit_group_assignment.initialized?
  end

  def has_active_health_coverage?(plan_year) # Related code is commented out
    benefit_group_ids = plan_year.benefit_groups.map(&:id)

    bg_assignment = active_benefit_group_assignment if benefit_group_ids.include?(active_benefit_group_assignment.try(:benefit_group_id))
    bg_assignment = renewal_benefit_group_assignment if benefit_group_ids.include?(renewal_benefit_group_assignment.try(:benefit_group_id))

    bg_assignment.present? && HbxEnrollment.enrolled_shop_health_benefit_group_ids([bg_assignment]).present?
  end

  def current_state
    if existing_cobra
      if COBRA_STATES.include? aasm_state
        aasm_state.humanize
      else
        'Cobra'
      end
    else
      aasm_state.humanize
    end
  end

  def update_for_cobra(cobra_date,current_user=nil)
    self.cobra_begin_date = cobra_date
    self.elect_cobra(current_user)
    self.save
  rescue => e
    false
  end

  def need_to_build_renewal_hbx_enrollment_for_cobra?
    renewal_benefit_group_assignment.present? && active_benefit_group_assignment != renewal_benefit_group_assignment
  end

  def build_hbx_enrollment_for_cobra
    family = employee_role.person.primary_family

    cobra_assignments = [active_benefit_group_assignment, renewal_benefit_group_assignment].compact
    hbxs = cobra_assignments.map(&:latest_hbx_enrollments_for_cobra).flatten.uniq rescue []

    hbxs.compact.each do |hbx|
      enrollment_cobra_factory = Factories::FamilyEnrollmentCloneFactory.new
      enrollment_cobra_factory.family = family
      enrollment_cobra_factory.census_employee = self
      enrollment_cobra_factory.enrollment = hbx
      enrollment_cobra_factory.clone_for_cobra
    end
  rescue => e
    logger.error(e)
  end

  class << self

    def enrolled_count(benefit_group)

        return 0 unless benefit_group

        cnt = CensusEmployee.collection.aggregate([
        {"$match" => {"benefit_group_assignments.benefit_group_id" => benefit_group.id  }},
        {"$unwind" => "$benefit_group_assignments"},
        {"$match" => {"aasm_state" => { "$in" =>  EMPLOYMENT_ACTIVE_STATES  } }},
        {"$match" => {"benefit_group_assignments.aasm_state" => { "$in" => ["coverage_selected"]} }},
        #{"$match" => {"benefit_group_assignments.is_active" => true}},
        {"$match" => {"benefit_group_assignments.benefit_group_id" => benefit_group.id  }},
        {"$group" => {
            "_id" =>  { "bgid" => "$benefit_group_assignments.benefit_group_id",
                        #"state" => "$aasm_state",
                        #{}"active" => "$benefit_group_assignments.is_active",
                        #{}"bgstate" => "$benefit_group_assignments.aasm_state"
                      },
                      "count" => { "$sum" => 1 }
                    }
              },
        #{"$match" => {"count" => {"$gte" => 1}}}
      ],
      :allow_disk_use => true)


      if cnt.count >= 1
        return cnt.first['count']
      else
        return 0
      end
    end

    def advance_day(new_date)
      CensusEmployee.terminate_scheduled_census_employees
      CensusEmployee.rebase_newly_designated_employees
      CensusEmployee.terminate_future_scheduled_census_employees(new_date)
      CensusEmployee.initial_employee_open_enrollment_notice(new_date)
      CensusEmployee.census_employee_open_enrollment_reminder_notice(new_date)
    end

    def initial_employee_open_enrollment_notice(date)
      census_employees = CensusEmployee.where(:"hired_on" => date).non_terminated
      census_employees.each do |ce|
        begin
          Invitation.invite_future_employee_for_open_enrollment!(ce)
        rescue Exception => e
          (Rails.logger.error { "Unable to deliver open enrollment notice to #{ce.full_name} due to --- #{e}" }) unless Rails.env.test?
        end
      end
    end

    def terminate_scheduled_census_employees(as_of_date = TimeKeeper.date_of_record)
      census_employees_for_termination = CensusEmployee.pending.where(:employment_terminated_on.lt => as_of_date)
      census_employees_for_termination.each do |census_employee|
        begin
          census_employee.terminate_employment(census_employee.employment_terminated_on)
        rescue Exception => e
          (Rails.logger.error { "Error while terminating cesus employee - #{census_employee.full_name} due to -- #{e}" }) unless Rails.env.test?
        end
      end
    end

    def rebase_newly_designated_employees
      return unless TimeKeeper.date_of_record.yday == 1
      CensusEmployee.where(:"aasm_state".in => NEWLY_DESIGNATED_STATES).each do |employee|
        begin
          employee.rebase_new_designee! if employee.may_rebase_new_designee?
        rescue Exception => e
          (Rails.logger.error { "Error while rebasing newly designated cesus employee - #{employee.full_name} due to #{e}" }) unless Rails.env.test?
        end
      end
    end

    def terminate_future_scheduled_census_employees(as_of_date)
      census_employees_for_termination = CensusEmployee.where(:aasm_state => "employee_termination_pending").select { |ce| ce.employment_terminated_on <= as_of_date}
      census_employees_for_termination.each do |census_employee|
        begin
          census_employee.terminate_employee_role!
        rescue Exception => e
          (Rails.logger.error { "Error while terminating future scheduled cesus employee - #{census_employee.full_name} due to #{e}" }) unless Rails.env.test?
        end
      end
    end

    def census_employee_open_enrollment_reminder_notice(date)
      organizations = Organization.where(:"employer_profile.plan_years" => {:$elemMatch => {:aasm_state.in => ["enrolling", "renewing_enrolling"], :open_enrollment_end_on => date+2.days}})
      organizations.each do |org|
        plan_year = org.employer_profile.plan_years.where(:aasm_state.in => ["enrolling", "renewing_enrolling"]).first
        #exclude congressional employees
        next if plan_year.benefit_groups.any?{|bg| bg.is_congress?}
        census_employees = org.employer_profile.census_employees.non_terminated
        census_employees.each do |ce|
          begin
            #exclude new hires
            next if (ce.new_hire_enrollment_period.cover?(date) || ce.new_hire_enrollment_period.first > date)
            ShopNoticesNotifierJob.perform_later(ce.id.to_s, "employee_open_enrollment_reminder")
          rescue Exception => e
            (Rails.logger.error { "Unable to deliver open enrollment reminder notice to #{ce.full_name} due to #{e}" }) unless Rails.env.test?
          end
        end
      end
    end

    def find_all_by_employer_profile(employer_profile)
      unscoped.where(employer_profile_id: employer_profile._id).order_name_asc
    end

    alias_method :find_by_employer_profile, :find_all_by_employer_profile

    def find_all_by_employee_role(employee_role)
      unscoped.where(employee_role_id: employee_role._id)
    end

    def find_all_by_benefit_group(benefit_group)
      unscoped.where("benefit_group_assignments.benefit_group_id" => benefit_group._id)
    end

    def find_all_terminated(employer_profiles: [], date_range: (TimeKeeper.date_of_record..TimeKeeper.date_of_record))

      if employer_profiles.size > 0
        employer_profile_ids = employer_profiles.map(&:_id)
        query = unscoped.terminated.any_in(employer_profile_id: employer_profile_ids).
                                    where(
                                      :employment_terminated_on.gte => date_range.first,
                                      :employment_terminated_on.lte => date_range.last
                                    )
      else
        query = unscoped.terminated.where(
                                    :employment_terminated_on.gte => date_range.first,
                                    :employment_terminated_on.lte => date_range.last
                                  )
      end
      query.to_a
    end

    # Update CensusEmployee records when Person record is updated. (SSN / DOB change)
    def update_census_employee_records(person, current_user)
      person.employee_roles.each do |employee_role|
        ce = employee_role.census_employee
        if current_user.has_hbx_staff_role? && ce.present?
          ce.ssn = person.ssn
          ce.dob = person.dob
          ce.save!(validate: false)
        end
      end
    end

    # Search query string on census employee with first name,last name,SSN.
    def search_hash(s_rex)
      clean_str = s_rex.strip.split.map{|i| Regexp.escape(i)}.join("|")
      action = s_rex.strip.split.size > 1 ? "$and" : "$or"
      search_rex = Regexp.compile(clean_str, true)
      {
          "$or" => [
              {action => [
                  {"first_name" => search_rex},
                  {"last_name" => search_rex}
              ]},
              {"encrypted_ssn" => encrypt_ssn(clean_str)}
          ]
      }
    end
  end

  aasm do
    state :eligible, initial: true
    state :cobra_eligible
    state :newly_designated_eligible    # congressional employee state with certain new hire rules
    state :employee_role_linked
    state :cobra_linked
    state :newly_designated_linked
    state :cobra_termination_pending
    state :employee_termination_pending
    state :employment_terminated
    state :cobra_terminated
    state :rehired

    event :newly_designate, :after => :record_transition do
      transitions from: :eligible, to: :newly_designated_eligible
      transitions from: :employee_role_linked, to: :newly_designated_linked
    end

    event :rebase_new_designee, :after => :record_transition do
      transitions from: :newly_designated_eligible, to: :eligible
      transitions from: :newly_designated_linked, to: :employee_role_linked
    end

    event :rehire_employee_role, :after => :record_transition do
      transitions from: [:employment_terminated, :cobra_eligible, :cobra_linked, :cobra_terminated], to: :rehired
    end

    event :elect_cobra, :guard => :have_valid_date_for_cobra?, :after => :record_transition do
      transitions from: :employment_terminated, to: :cobra_linked, :guard => :has_employee_role_linked?, after: :build_hbx_enrollment_for_cobra
      transitions from: :employment_terminated, to: :cobra_eligible
    end

    event :link_employee_role, :after => :record_transition do
      transitions from: :eligible, to: :employee_role_linked, :guard => :has_benefit_group_assignment?
      transitions from: :cobra_eligible, to: :cobra_linked, guard: :has_benefit_group_assignment?
      transitions from: :newly_designated_eligible, to: :newly_designated_linked, :guard => :has_benefit_group_assignment?
    end

    event :delink_employee_role, :guard => :has_no_hbx_enrollments?, :after => :record_transition do
      transitions from: :employee_role_linked, to: :eligible, :after => :clear_employee_role
      transitions from: :newly_designated_linked, to: :newly_designated_eligible, :after => :clear_employee_role
      transitions from: :cobra_linked, to: :cobra_eligible, after: :clear_employee_role
    end

    event :schedule_employee_termination, :after => :record_transition do
      transitions from: [:employee_termination_pending, :eligible, :employee_role_linked, :newly_designated_eligible, :newly_designated_linked], to: :employee_termination_pending
      transitions from: [:cobra_termination_pending, :cobra_eligible, :cobra_linked],  to: :cobra_termination_pending
    end

    event :terminate_employee_role, :after => :record_transition do
      transitions from: [:eligible, :employee_role_linked, :employee_termination_pending, :newly_designated_eligible, :newly_designated_linked], to: :employment_terminated
      transitions from: [:cobra_eligible, :cobra_linked, :cobra_termination_pending],  to: :cobra_terminated
    end

    event :reinstate_eligibility, :after => [:record_transition] do
      transitions from: :employment_terminated, to: :employee_role_linked, :guard => :has_employee_role_linked?
      transitions from: :employment_terminated,  to: :eligible
      transitions from: :cobra_terminated, to: :cobra_linked, :guard => :has_employee_role_linked?
      transitions from: :cobra_terminated, to: :cobra_eligible
    end

  end

  def self.roster_import_fallback_match(f_name, l_name, dob, bg_id)
    fname_exp = Regexp.compile(Regexp.escape(f_name), true)
    lname_exp = Regexp.compile(Regexp.escape(l_name), true)
    self.where({
      first_name: fname_exp,
      last_name: lname_exp,
      dob: dob
    }).any_in("benefit_group_assignments.benefit_group_id" => [bg_id])
  end

  def self.to_csv

    columns = [
      "Family ID # (to match family members to the EE & each household gets a unique number)(optional)",
      "Relationship (EE, Spouse, Domestic Partner, or Child)",
      "Last Name",
      "First Name",
      "Middle Name or Initial (optional)",
      "Suffix (optional)",
      "Email Address",
      "SSN / TIN (Required for EE & enter without dashes)",
      "Date of Birth (MM/DD/YYYY)",
      "Gender",
      "Date of Hire",
      "Date of Termination (optional)",
      "Is Business Owner?",
      "Benefit Group (optional)",
      "Plan Year (Optional)",
      "Address Kind(Optional)",
      "Address Line 1(Optional)",
      "Address Line 2(Optional)",
      "City(Optional)",
      "State(Optional)",
      "Zip(Optional)"
    ]

    CSV.generate(headers: true) do |csv|
      csv << (["#{Settings.site.long_name} Employee Census Template"] +  6.times.collect{ "" } + [Date.new(2016,10,26)] + 5.times.collect{ "" } + ["1.1"])
      csv << %w(employer_assigned_family_id employee_relationship last_name first_name  middle_name name_sfx  email ssn dob gender  hire_date termination_date  is_business_owner benefit_group plan_year kind  address_1 address_2 city  state zip)
      csv << columns
      all.each do |census_employee|
        ([census_employee] + census_employee.census_dependents.to_a).each do |census_member|
          values = [
            census_member.employer_assigned_family_id,
            census_member.relationship_string,
            census_member.last_name,
            census_member.first_name,
            census_member.middle_name,
            census_member.name_sfx,
            census_member.email_address,
            census_member.ssn,
            census_member.dob.strftime("%m/%d/%Y"),
            census_member.gender
          ]

          if census_member.is_a?(CensusEmployee)
            values += [
              census_member.hired_on.present? ? census_member.hired_on.strftime("%m/%d/%Y") : "",
              census_member.employment_terminated_on.present? ? census_member.employment_terminated_on.strftime("%m/%d/%Y") : "",
              census_member.is_business_owner ? "yes" : "no"
            ]
          else
            values += ["", "", "no"]
          end

          values += 2.times.collect{ "" }
          if census_member.address.present?
            values += census_member.address.to_a
          else
            values += 6.times.collect{ "" }
          end

          csv << values
        end
      end
    end
  end

  def existing_cobra
    COBRA_STATES.include? aasm_state
  end

  def existing_cobra=(cobra)
    self.aasm_state = 'cobra_eligible' if cobra == 'true'
  end

  def is_cobra_status?
    existing_cobra
  end

  def can_elect_cobra?
    ['employment_terminated'].include?(aasm_state)
  end

  def have_valid_date_for_cobra?(current_user = nil)
    return true if current_user.try(:has_hbx_staff_role?)
    return false unless cobra_begin_date.present?
    return false unless coverage_terminated_on
    return false unless coverage_terminated_on <= cobra_begin_date

    (hired_on <= cobra_begin_date) &&
      (TimeKeeper.date_of_record <= (coverage_terminated_on + aca_shop_market_cobra_enrollment_period_in_months.months)) &&
      cobra_begin_date <= (coverage_terminated_on + aca_shop_market_cobra_enrollment_period_in_months.months)
  end

  def has_employee_role_linked?
    employee_role.present?
  end

  # should disable cobra
  # 1.waived
  # 2.do not have an enrollment
  # 3.census_employee is pending
  def is_disabled_cobra_action?
    employee_role.blank? || active_benefit_group_assignment.blank? || active_benefit_group_assignment.coverage_waived? ||
      (active_benefit_group_assignment.hbx_enrollment.blank? && active_benefit_group_assignment.hbx_enrollments.blank?) ||
      employee_termination_pending?
  end

  def has_cobra_hbx_enrollment?
    return false if active_benefit_group_assignment.blank? || active_benefit_group_assignment.hbx_enrollment.blank?
    active_benefit_group_assignment.hbx_enrollment.is_cobra_status?
  end

  def need_update_hbx_enrollment_effective_on?
    !has_cobra_hbx_enrollment? && coverage_terminated_on.present?
  end

  def show_plan_end_date?
    is_inactive? && coverage_terminated_on.present?
  end

  def is_included_in_participation_rate?
    return true if coverage_terminated_on.nil?
    return false if active_benefit_group_assignment.nil?
    coverage_terminated_on >= active_benefit_group_assignment.start_on
  end

  def enrollments_for_display
    enrollments = []

    coverages_selected = lambda do |benefit_group_assignment|
      return [] if benefit_group_assignment.blank?
      coverages = benefit_group_assignment.active_and_waived_enrollments.reject{|e| e.external_enrollment }
      [coverages.detect{|c| c.coverage_kind == 'health'}, coverages.detect{|c| c.coverage_kind == 'dental'}]
    end

    enrollments += coverages_selected.call(active_benefit_group_assignment)
    enrollments += coverages_selected.call(renewal_benefit_group_assignment)
    enrollments.compact.uniq
  end


  def expected_to_enroll?
    expected_selection == 'enroll'
  end

  def expected_to_enroll_or_valid_waive?
    %w(enroll waive).include?  expected_selection
  end

  # TODO: Implement for 16219
  def composite_rating_tier
    return CompositeRatingTier::EMPLOYEE_ONLY if self.census_dependents.empty?
    relationships = self.census_dependents.map(&:employee_relationship)
    if (relationships.include?("spouse") || relationships.include?("domestic_partner"))
      relationships.many? ? CompositeRatingTier::FAMILY : CompositeRatingTier::EMPLOYEE_AND_SPOUSE
    else
      CompositeRatingTier::EMPLOYEE_AND_ONE_OR_MORE_DEPENDENTS
    end
  end

  private

  def record_transition
    self.workflow_state_transitions << WorkflowStateTransition.new(
      from_state: aasm.from_state,
      to_state: aasm.to_state
    )
  end

  def set_autocomplete_slug
    return unless (first_name.present? && last_name.present?)
    @autocomplete_slug = first_name.concat(" #{last_name}")
  end

  def has_no_hbx_enrollments?
    return true if employee_role.blank?
    !benefit_group_assignments.detect { |bga| bga.hbx_enrollment.present? }
  end

  def check_employment_terminated_on
    return false if is_cobra_status?

    if employment_terminated_on && employment_terminated_on <= hired_on
      errors.add(:employment_terminated_on, "can't occur before hiring date")
    end

    if !self.employment_terminated? && !self.rehired?
      if employment_terminated_on && employment_terminated_on <= TimeKeeper.date_of_record - 60.days
        errors.add(:employment_terminated_on, "Employee termination must be within the past 60 days")
      end
    end
  end

  def check_cobra_begin_date
    if existing_cobra && hired_on > cobra_begin_date
      errors.add(:cobra_begin_date, 'must be after Hire Date')
    end
  end

  def no_duplicate_census_dependent_ssns
    dependents_ssn = census_dependents.map(&:ssn).select(&:present?)
    if dependents_ssn.uniq.length != dependents_ssn.length ||
       dependents_ssn.any?{|dep_ssn| dep_ssn==self.ssn}
      errors.add(:base, "SSN's must be unique for each dependent and subscriber")
    end
  end

  def active_census_employee_is_unique
    potential_dups = CensusEmployee.by_ssn(ssn).by_employer_profile_id(employer_profile_id).active
    if potential_dups.detect { |dup| dup.id != self.id  }
      message = "Employee with this identifying information is already active. "\
                "Update or terminate the active record before adding another."
      errors.add(:base, message)
    end
  end

  def check_census_dependents_relationship
    return true if census_dependents.blank?

    relationships = census_dependents.map(&:employee_relationship)
    if relationships.count{|rs| rs=='spouse' || rs=='domestic_partner'} > 1
      errors.add(:census_dependents, "can't have more than one spouse or domestic partner.")
    end
  end

  # SSN and DOB values may be edited only in pre-linked status
  def allow_id_info_changes_only_in_eligible_state
    if (ssn_changed? || dob_changed?) && !ELIGIBLE_STATES.include?(aasm_state)
      message = "An employee's identifying information may change only when in 'eligible' status. "
      errors.add(:base, message)
    end
  end

  def check_hired_on_before_dob
    if hired_on && dob && hired_on <= dob
      errors.add(:hired_on, "date can't be before  date of birth.")
    end
  end

  def clear_employee_role
    # employee_role.
    self.employee_role_id = nil
    unset("employee_role_id")
    self.benefit_group_assignments = []
    @employee_role = nil
  end

  def notify_terminated
    notify(EMPLOYEE_TERMINATED_EVENT_NAME, { :census_employee_id => self.id } )
  end

  def notify_cobra_terminated
    notify(EMPLOYEE_COBRA_TERMINATED_EVENT_NAME, { :census_employee_id => self.id } )
  end
end

class CensusEmployeeError < StandardError; end
