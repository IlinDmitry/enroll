class PlanYear
  include Mongoid::Document
  include SetCurrentUser
  include Mongoid::Timestamps
  include AASM
  include Acapi::Notifiers
  include Concerns::Observable
  include ModelEvents::PlanYear

  embedded_in :employer_profile

  PUBLISHED = %w(published enrolling enrollment_extended enrolled active suspended)
  RENEWING  = %w(renewing_draft renewing_published renewing_enrolling renewing_enrollment_extended renewing_enrolled renewing_publish_pending)
  RENEWING_PUBLISHED_STATE = %w(renewing_published renewing_enrolling renewing_enrollment_extended renewing_enrolled)
  TERMINATED_STATE = %w(termination_pending terminated expired)

  INELIGIBLE_FOR_EXPORT_STATES = %w(draft publish_pending eligibility_review published_invalid canceled renewing_draft suspended application_ineligible renewing_application_ineligible renewing_canceled conversion_expired)

  OPEN_ENROLLMENT_STATE   = %w(enrolling enrollment_extended renewing_enrolling renewing_enrollment_extended)
  INITIAL_ENROLLING_STATE = %w(publish_pending eligibility_review published published_invalid enrolling enrollment_extended enrolled)
  INITIAL_ELIGIBLE_STATE  = %w(published enrolling enrollment_extended enrolled) 

  VOLUNTARY_TERMINATED_PLAN_YEAR_EVENT_TAG = "benefit_coverage_period_terminated_voluntary"
  VOLUNTARY_TERMINATED_PLAN_YEAR_EVENT = "acapi.info.events.employer.benefit_coverage_period_terminated_voluntary"

  NON_PAYMENT_TERMINATED_PLAN_YEAR_EVENT_TAG = "benefit_coverage_period_terminated_nonpayment"
  NON_PAYMENT_TERMINATED_PLAN_YEAR_EVENT = "acapi.info.events.employer.benefit_coverage_period_terminated_nonpayment"

  INITIAL_OR_RENEWAL_PLAN_YEAR_DROP_EVENT_TAG="benefit_coverage_renewal_carrier_dropped"
  INITIAL_OR_RENEWAL_PLAN_YEAR_DROP_EVENT="acapi.info.events.employer.benefit_coverage_renewal_carrier_dropped"

  # Plan Year time period
  field :start_on, type: Date
  field :end_on, type: Date

  field :open_enrollment_start_on, type: Date
  field :open_enrollment_end_on, type: Date

  field :terminated_on, type: Date
  field :termination_kind, type: String

  field :imported_plan_year, type: Boolean, default: false

  # Plan year created to support Employer converted into system. May not be complaint with Hbx Business Rules
  field :is_conversion, type: Boolean, default: false

  # Number of full-time employees
  field :fte_count, type: Integer, default: 0

  # Number of part-time employess
  field :pte_count, type: Integer, default: 0

  # Number of Medicare Second Payers
  field :msp_count, type: Integer, default: 0

  # Calculated Fields for DataTable
  field :enrolled_summary, type: Integer, default: 0
  field :waived_summary, type: Integer, default: 0

  # Workflow attributes
  field :aasm_state, type: String, default: :draft

  embeds_many :benefit_groups, cascade_callbacks: true
  embeds_many :workflow_state_transitions, as: :transitional

  accepts_nested_attributes_for :benefit_groups, :workflow_state_transitions

  validates_presence_of :start_on, :end_on, :open_enrollment_start_on, :open_enrollment_end_on, :message => "is invalid"

  validate :open_enrollment_date_checks

  # scope :not_yet_active, ->{ any_in(aasm_state: %w(published enrolling enrolled)) }

  scope :published,         ->{ any_in(aasm_state: PUBLISHED) }
  scope :renewing_published_state, ->{ any_in(aasm_state: RENEWING_PUBLISHED_STATE) }
  scope :renewing,          ->{ any_in(aasm_state: RENEWING) }

  scope :published_or_renewing_published, -> { any_of([published.selector, renewing_published_state.selector]) }
  scope :published_or_renewing_published_or_terminated, -> { any_in(aasm_state: PUBLISHED + RENEWING_PUBLISHED_STATE + TERMINATED_STATE) }
  scope :renewing_draft_or_draft, -> { any_in(aasm_state: %w[draft renewing_draft]) }

  scope :by_date_range,     ->(begin_on, end_on) { where(:"start_on".gte => begin_on, :"start_on".lte => end_on) }
  scope :published_plan_years_within_date_range, ->(begin_on, end_on) {
    where(
      "$and" => [
        {:aasm_state.in => PUBLISHED },
        {"$or" => [
          { :start_on => {"$gte" => begin_on, "$lte" => end_on }},
          { :end_on => {"$gte" => begin_on, "$lte" => end_on }}
        ]
      }
    ]
    )
  }

  scope :published_plan_years_by_date, ->(date) {
    where(
      "$and" => [
        {:aasm_state.in => PUBLISHED },
        {:"start_on".lte => date, :"end_on".gte => date}
      ]
    )
  }

  scope :published_and_expired_plan_years_by_date, ->(date) {
    where(
      "$and" => [
        {:aasm_state.in => PUBLISHED + ['expired'] },
        {:"start_on".lte => date, :"end_on".gte => date}
      ]
    )
  }

  scope :published_or_renewing_published_plan_years_by_date, ->(date) {
    where(
      "$and" => [
        {:aasm_state.in => (PUBLISHED + RENEWING_PUBLISHED_STATE) },
        {:"start_on".lte => date, :"end_on".gte => date}
      ]
    )
  }

  scope :by_overlapping_coverage_period, ->(start_on, end_on) {
    where(
      "$or" => [
        { :"start_on" => {"$gte" => start_on, "$lte" => end_on }},
        { :"end_on" => {"$gte" => start_on, "$lte" => end_on }}
      ]
    )
  }

  after_update :update_employee_benefit_packages

  after_save :notify_on_save

  def update_employee_benefit_packages
    if self.start_on_changed?
      census_employees_within_play_year.each do |census_employee|
        census_employee.benefit_group_assignments.where(:benefit_group_id.in => benefit_group_ids).each do |assignment|
          assignment.update(start_on: self.start_on)
          assignment.update(end_on: self.end_on) if assignment.end_on.present?
        end
      end
    end
  end

  # This is being used by Open enrollment extension feature
  # Admin can't choose date before regular monthly open enrollment end date
  # Admin can't choose a date beyond the effective month of the application. 
  #   ex: For 1/1 application we limit calender from 12/10 to 1/31.
  def open_enrollment_date_bounds
    {
      min: [TimeKeeper.date_of_record, PlanYear.calculate_open_enrollment_date(start_on)[:open_enrollment_end_on]].max,
      max: effective_date.end_of_month
    }
  end

  def activate_employee_benefit_packages
    census_employees_within_play_year.each do |census_employee|
      assignment = census_employee.benefit_group_assignments_for(self).first
      assignment.make_active if assignment.present?
    end
  end

  #Updating end_on with start_on for XML purposes only.
  def update_end_date
    self.update_attributes!(:end_on => self.start_on)
  end

  def benefit_group_ids
    self.benefit_groups.map(&:id).uniq
  end

  def census_employees_within_play_year
    CensusEmployee.where({ :"benefit_group_assignments.benefit_group_id".in => benefit_group_ids }).non_terminated
  end

  def cancel_renewal_plan_year_if_any
    renewing_plan_year = parent.plan_years.where(:aasm_state.in => RENEWING + ['renewing_application_ineligible']).first
    if renewing_plan_year
      renewing_plan_year.cancel_renewal! if renewing_plan_year.may_cancel_renewal?
    end
    renewing_plan_year
  end

  def terminate_plan_year(end_on, terminated_on, termination_kind, transmit_xml, enrollment_term_reason)
    renewing_plan_year = parent.plan_years.where(:aasm_state.in => RENEWING + ['renewing_application_ineligible']).first

    if renewing_plan_year
      renewing_plan_year.cancel_renewal!(transmit_xml) if renewing_plan_year.may_cancel_renewal?
    end
    if end_on >= TimeKeeper.date_of_record
      if may_schedule_termination?
        set_plan_year_termination_date(end_on, {termination_kind: termination_kind, terminated_on: terminated_on})
        schedule_termination!
        terminate_employee_enrollments(end_on, {transmit_xml: transmit_xml, enrollment_term_reason: enrollment_term_reason})
        notify_employer_py_terminate(transmit_xml)
      end
    elsif may_terminate?
      set_plan_year_termination_date(end_on, {termination_kind: termination_kind, terminated_on: terminated_on})
      terminate!(end_on)
      notify_employer_py_terminate(transmit_xml)
      terminate_employee_enrollments(end_on, {transmit_xml: transmit_xml, enrollment_term_reason: enrollment_term_reason})
      employer_profile.revert_application! if employer_profile.may_revert_application?
    end
  end

  def terminate_employee_benefit_packages(*args)
    py_end_on = args.first
    census_employees_within_play_year.each do |census_employee|
      census_employee.benefit_group_assignments.where(:benefit_group_id.in => benefit_group_ids).each do |assignment|
        if ((assignment.end_on.present? && (assignment.end_on > py_end_on)) || assignment.end_on.blank?)
          assignment.update_attributes!(end_on: py_end_on)
          assignment.terminate_coverage! if assignment.may_terminate_coverage?
        end
      end
    end
  end

  def cancel_employee_benefit_packages(*args)
    census_employees_within_play_year.each do |census_employee|
      census_employee.benefit_group_assignments.where(:benefit_group_id.in => benefit_group_ids).each do |assignment|
        if assignment.may_delink_coverage?
          assignment.delink_coverage!
          assignment.update_attributes!(end_on: assignment.plan_year.end_on, is_active: false)
        end
      end
    end
  end

  def enrollments_for_plan_year
    id_list = self.benefit_groups.map(&:id)
    families = Family.where(:"households.hbx_enrollments.benefit_group_id".in => id_list)
    enrollment_selector = [HbxEnrollment::enrolled.selector, HbxEnrollment::renewing.selector, HbxEnrollment::waived.selector, HbxEnrollment::terminated.selector]
    enrollments = families.inject([]) do |enrollments, family|
      enrollments += family.active_household.hbx_enrollments.where(:benefit_group_id.in => id_list).any_of(enrollment_selector).to_a
    end
  end

  def cancel_employee_enrollments(transmit_xml = false)
    enrollments_for_plan_year.each do |hbx_enrollment|
      if hbx_enrollment.may_cancel_coverage?
        if hbx_enrollment.inactive?
          hbx_enrollment.cancel_coverage!
        else
          hbx_enrollment.cancel_coverage!
          hbx_enrollment.notify_enrollment_cancel_or_termination_event(transmit_xml) if eligible_for_export?
        end
      end
    end
  end

  def terminate_employee_enrollments(py_end_on, options= {})
    enrollments_for_plan_year.each do |hbx_enrollment|
      if hbx_enrollment.effective_on > py_end_on
        hbx_enrollment.cancel_coverage! if hbx_enrollment.may_cancel_coverage?
        hbx_enrollment.notify_enrollment_cancel_or_termination_event(options[:transmit_xml])
      else
        if hbx_enrollment.coverage_termination_pending? && hbx_enrollment.terminated_on.present? && (hbx_enrollment.terminated_on < py_end_on)
          #do nothing
        elsif py_end_on < TimeKeeper.date_of_record
          if hbx_enrollment.may_terminate_coverage?
            if hbx_enrollment.terminated_on.nil? || (hbx_enrollment.terminated_on.present? && (hbx_enrollment.terminated_on > py_end_on))
              hbx_enrollment.terminate_coverage!(py_end_on)
              hbx_enrollment.update_attributes!(termination_submitted_on: TimeKeeper.date_of_record, terminate_reason: options[:enrollment_term_reason])
              hbx_enrollment.notify_enrollment_cancel_or_termination_event(options[:transmit_xml])
            end
          end
        else
          if hbx_enrollment.may_schedule_coverage_termination?
            hbx_enrollment.schedule_coverage_termination!(py_end_on)
            hbx_enrollment.update_attributes!(termination_submitted_on: TimeKeeper.date_of_record, terminate_reason: options[:enrollment_term_reason])
            hbx_enrollment.notify_enrollment_cancel_or_termination_event(options[:transmit_xml])
          end
        end
      end
    end
  end

  def filter_active_enrollments_by_date(date)
    id_list = benefit_groups.collect(&:_id).uniq
    enrollment_proxies = Family.collection.aggregate([
      # Thin before expanding to make better use of indexes
      {"$match" => { "households.hbx_enrollments" => {
        "$elemMatch" => {
        "benefit_group_id" => {
          "$in" => id_list
        },
        "aasm_state" => { "$in" => (HbxEnrollment::ENROLLED_STATUSES + HbxEnrollment::RENEWAL_STATUSES + HbxEnrollment::TERMINATED_STATUSES + HbxEnrollment::WAIVED_STATUSES)},
        "effective_on" =>  {"$lte" => date.end_of_month, "$gte" => self.start_on}
      }}}},
      {"$unwind" => "$households"},
      {"$unwind" => "$households.hbx_enrollments"},
      {"$match" => {
        "households.hbx_enrollments.benefit_group_id" => {
          "$in" => id_list
        },
        "households.hbx_enrollments.aasm_state" => { "$in" => (HbxEnrollment::ENROLLED_STATUSES + HbxEnrollment::RENEWAL_STATUSES + HbxEnrollment::TERMINATED_STATUSES + HbxEnrollment::WAIVED_STATUSES)},
        "households.hbx_enrollments.effective_on" =>  {"$lte" => date.end_of_month, "$gte" => self.start_on},
        "$or" => [
         {"households.hbx_enrollments.terminated_on" => {"$eq" => nil} },
         {"households.hbx_enrollments.terminated_on" => {"$gte" => date.end_of_month}}
        ]
      }},
      {"$sort" => {
        "households.hbx_enrollments.submitted_at" => 1
      }},
      {"$group" => {
        "_id" => {
          "bga_id" => "$households.hbx_enrollments.benefit_group_assignment_id",
          "coverage_kind" => "$households.hbx_enrollments.coverage_kind"
        },
        "hbx_enrollment_id" => {"$last" => "$households.hbx_enrollments._id"},
        "aasm_state" => {"$last" => "$households.hbx_enrollments.aasm_state"},
        "plan_id" => {"$last" => "$households.hbx_enrollments.plan_id"},
        "benefit_group_id" => {"$last" => "$households.hbx_enrollments.benefit_group_id"},
        "benefit_group_assignment_id" => {"$last" => "$households.hbx_enrollments.benefit_group_assignment_id"},
        "family_members" => {"$last" => "$family_members"}
      }},
      {"$match" => {"aasm_state" => {"$nin" => HbxEnrollment::WAIVED_STATUSES}}}
    ])
    return [] if (enrollment_proxies.count > Settings.aca.shop_market.small_market_active_employee_limit)
    enrollment_proxies.map do |ep|
      OpenStruct.new(ep)
    end
  end

  def hbx_enrollments_by_month(date)
    id_list = benefit_groups.collect(&:_id).uniq
    families = Family.where({
      :"households.hbx_enrollments.benefit_group_id".in => id_list,
      :"households.hbx_enrollments.aasm_state".in => (HbxEnrollment::ENROLLED_STATUSES + HbxEnrollment::RENEWAL_STATUSES + HbxEnrollment::TERMINATED_STATUSES)
      }).limit(Settings.aca.shop_market.small_market_active_employee_limit)

    families.inject([]) do |enrollments, family|
      valid_enrollments = family.active_household.hbx_enrollments.where({
        :benefit_group_id.in => id_list,
        :effective_on.lte => date.end_of_month,
        :aasm_state.in => (HbxEnrollment::ENROLLED_STATUSES + HbxEnrollment::RENEWAL_STATUSES + HbxEnrollment::TERMINATED_STATUSES)
      }).order_by(:'submitted_at'.desc)

      health_enrollments = valid_enrollments.where({:coverage_kind => 'health'})
      dental_enrollments = valid_enrollments.where({:coverage_kind => 'dental'})

      coverage_filter = lambda do |enrollments, date|
        enrollments = enrollments.select{|e| e.terminated_on.blank? || e.terminated_on >= date}

        if enrollments.size > 1
          enrollment = enrollments.detect{|e| (HbxEnrollment::ENROLLED_STATUSES + HbxEnrollment::TERMINATED_STATUSES).include?(e.aasm_state.to_s)}
          enrollment || enrollments.detect{|e| HbxEnrollment::RENEWAL_STATUSES.include?(e.aasm_state.to_s)}
        else
          enrollments.first
        end
      end

      enrollments << coverage_filter.call(health_enrollments, date)
      enrollments << coverage_filter.call(dental_enrollments, date)
    end.compact
  end

  def open_enrollment_completed?
    return false if open_enrollment_end_on.blank?
    (TimeKeeper.date_of_record > open_enrollment_end_on)
  end

  def binder_paid?
    employer_profile.binder_paid?
  end

  def past_transmission_threshold?
    return false if start_on.blank?
    t_threshold_date = (start_on - 1.month).beginning_of_month + 14.days
    (TimeKeeper.date_of_record > t_threshold_date)
  end

  def eligible_for_export?
    return false if self.aasm_state.blank?
    return false if is_conversion?
    if start_on.blank?
      return(false)
    end
    if INELIGIBLE_FOR_EXPORT_STATES.include?(self.aasm_state.to_s)
      return false
    end
    if (TimeKeeper.date_of_record < start_on)
      if enrolled?
        if open_enrollment_completed? && binder_paid? && past_transmission_threshold?
          return true
        end
      elsif renewing_enrolled?
        if open_enrollment_completed? && past_transmission_threshold?
          return true
        end
      end
      return false
    end
    true
  end

  def overlapping_published_plan_years
    self.employer_profile.plan_years.published_plan_years_within_date_range(self.start_on, self.end_on)
  end

  def parent
    raise "undefined parent employer_profile" unless employer_profile?
    self.employer_profile
  end

  def start_on=(new_date)
    new_date = Date.parse(new_date) if new_date.is_a? String
    write_attribute(:start_on, new_date.beginning_of_day)
  end

  def end_on=(new_date)
    new_date = Date.parse(new_date) if new_date.is_a? String
    write_attribute(:end_on, new_date.end_of_day)
  end

  def open_enrollment_start_on=(new_date)
    new_date = Date.parse(new_date) if new_date.is_a? String
    write_attribute(:open_enrollment_start_on, new_date.beginning_of_day)
  end

  def open_enrollment_end_on=(new_date)
    new_date = Date.parse(new_date) if new_date.is_a? String
    write_attribute(:open_enrollment_end_on, new_date.end_of_day)
  end

  alias_method :effective_date=, :start_on=
  alias_method :effective_date, :start_on

  def terminate_application(termination_date)
    if coverage_period_contains?(termination_date)
      self.terminated_on = termination_date
      terminate
    end
  end

  def hbx_enrollments
    @hbx_enrollments = [] if benefit_groups.size == 0
    return @hbx_enrollments if defined? @hbx_enrollments
    @hbx_enrollments = HbxEnrollment.find_by_benefit_groups(benefit_groups)
  end

  def employee_participation_percent
    return "-" if eligible_to_enroll_count == 0
    "#{(total_enrolled_count / eligible_to_enroll_count.to_f * 100).round(2)}%"
  end

  def employee_participation_percent_based_on_summary
    return "-" if eligible_to_enroll_count == 0
    "#{(enrolled_summary / eligible_to_enroll_count.to_f * 100).round(2)}%"
  end

  def external_plan_year?
    employer_profile.is_conversion? && coverage_period_contains?(employer_profile.registered_on)
  end

  def editable?
    !benefit_groups.any?(&:assigned?)
  end

  def open_enrollment_contains?(compare_date)
    (open_enrollment_start_on.beginning_of_day <= compare_date.beginning_of_day) &&
    (compare_date.end_of_day <= open_enrollment_end_on.end_of_day)
  end

  def coverage_period_contains?(compare_date)
    return (start_on <= compare_date) if (end_on.blank?)
    (start_on.beginning_of_day <= compare_date.beginning_of_day) &&
    (compare_date.end_of_day <= end_on.end_of_day)
  end

  def is_renewing?
    RENEWING.include?(aasm_state)
  end

  def is_published?
    PUBLISHED.include?(aasm_state)
  end

  def default_benefit_group
    benefit_groups.detect(&:default)
  end

  def is_offering_dental?
    benefit_groups.any?{|bg| bg.is_offering_dental?}
  end

  def carriers_offered
    benefit_groups.inject([]) do |carriers, bg|
      carriers += bg.carriers_offered
    end.uniq
  end

  def dental_carriers_offered
    return [] unless is_offering_dental?
    benefit_groups.inject([]) do |carriers, bg|
      carriers += bg.dental_carriers_offered
    end.uniq
  end

  def default_renewal_benefit_group
    # benefit_groups.detect { |bg| bg.is_default? && is_coverage_renewing? }
  end

  def minimum_employer_contribution
    unless benefit_groups.size == 0
      benefit_groups.map do |benefit_group|
        benefit_group.relationship_benefits.select do |relationship_benefit|
          relationship_benefit.relationship == "employee"
        end.min_by do |relationship_benefit|
          relationship_benefit.premium_pct
        end
      end.map(&:premium_pct).first
    end
  end

  def assigned_census_employees
    benefit_groups.flat_map(){ |benefit_group| benefit_group.census_employees.active }
  end

  def assigned_census_employees_without_owner
    benefit_groups.flat_map(){ |benefit_group| benefit_group.census_employees.active.non_business_owner }
  end

  def is_application_unpublishable?
    open_enrollment_date_errors.present? || application_errors.present?
  end

  def is_application_valid?
    application_errors.blank?
  end

  def is_application_invalid?
    application_errors.present?
  end

  def is_application_eligible?
    application_eligibility_warnings.blank?
  end

  def due_date_for_publish
    if employer_profile.plan_years.renewing.any?
      Date.new(start_on.prev_month.year, start_on.prev_month.month, Settings.aca.shop_market.renewal_application.publish_due_day_of_month)
    else
      Date.new(start_on.prev_month.year, start_on.prev_month.month, Settings.aca.shop_market.initial_application.publish_due_day_of_month)
    end
  end

  def is_publish_date_valid?
    event_name = aasm.current_event.to_s.gsub(/!/, '')
    event_name == "force_publish" ? true : (TimeKeeper.datetime_of_record <= due_date_for_publish.end_of_day)
  end

  def open_enrollment_date_errors
    errors = {}

    if is_renewing?
      minimum_length = Settings.aca.shop_market.renewal_application.open_enrollment.minimum_length.days
      enrollment_end = Settings.aca.shop_market.renewal_application.monthly_open_enrollment_end_on
    else
      minimum_length = Settings.aca.shop_market.open_enrollment.minimum_length.days
      enrollment_end = Settings.aca.shop_market.open_enrollment.monthly_end_on
    end

    if (open_enrollment_end_on - (open_enrollment_start_on - 1.day)).to_i < minimum_length
      log_message(errors) {{open_enrollment_period: "Open Enrollment period is shorter than minimum (#{minimum_length} days)"}}
    end

    if open_enrollment_end_on > Date.new(start_on.prev_month.year, start_on.prev_month.month, enrollment_end)
      log_message(errors) {{open_enrollment_period: "Open Enrollment must end on or before the #{enrollment_end.ordinalize} day of the month prior to effective date"}}
    end

    errors
  end

  # Check plan year for violations of model integrity relative to publishing
  def application_errors
    errors = {}

    if open_enrollment_end_on > (open_enrollment_start_on + (Settings.aca.shop_market.open_enrollment.maximum_length.months).months)
      log_message(errors){{open_enrollment_period: "Open Enrollment period is longer than maximum (#{Settings.aca.shop_market.open_enrollment.maximum_length.months} months)"}}
    end

    if benefit_groups.any?{|bg| bg.reference_plan_id.blank? }
      log_message(errors){{benefit_groups: "Reference plans have not been selected for benefit groups. Please edit the plan year and select reference plans."}}
    end

    if benefit_groups.blank?
      log_message(errors) {{benefit_groups: "You must create at least one benefit group to publish a plan year"}}
    end

    if employer_profile.census_employees.active.to_set != assigned_census_employees.to_set
      log_message(errors) {{benefit_groups: "Every employee must be assigned to a benefit group defined for the published plan year"}}
    end

    if employer_profile.ineligible?
      log_message(errors) {{employer_profile:  "This employer is ineligible to enroll for coverage at this time"}}
    end

    if overlapping_published_plan_year?
      log_message(errors) {{ publish: "You may only have one published plan year at a time" }}
    end

    if !is_publish_date_valid?
      log_message(errors) {{publish: "Plan year starting on #{start_on.strftime("%m-%d-%Y")} must be published by #{due_date_for_publish.strftime("%m-%d-%Y")}"}}
    end

    errors
  end


  # Check plan year application for regulatory compliance
  def application_eligibility_warnings
    warnings = {}

    unless employer_profile.is_primary_office_local?
      warnings.merge!({primary_office_location: "Has its principal business address in the #{Settings.aca.state_name} and offers coverage to all full time employees through #{Settings.site.short_name} or Offers coverage through #{Settings.site.short_name} to all full time employees whose Primary worksite is located in the #{Settings.aca.state_name}"})
    end

    # Application is in ineligible state from prior enrollment activity
    if (aasm_state == "application_ineligible" || aasm_state == "renewing_application_ineligible") && !(["enrollment_extended", "renewing_enrollment_extended"].include?(aasm.to_state.to_s))
      warnings.merge!({ineligible: "Application did not meet eligibility requirements for enrollment"})
    end

    # Maximum company size at time of initial registration on the HBX
    if !(is_renewing?) && (fte_count > Settings.aca.shop_market.small_market_employee_count_maximum)
      warnings.merge!({ fte_count: "Has #{Settings.aca.shop_market.small_market_employee_count_maximum} or fewer full time equivalent employees" })
    end

    # Exclude Jan 1 effective date from certain checks
    unless effective_date.yday == 1
      # Employer contribution toward employee premium must meet minimum
      if benefit_groups.size > 0 && (minimum_employer_contribution < Settings.aca.shop_market.employer_contribution_percent_minimum)
        warnings.merge!({ minimum_employer_contribution:  "Employer contribution percent toward employee premium (#{minimum_employer_contribution.to_i}%) is less than minimum allowed (#{Settings.aca.shop_market.employer_contribution_percent_minimum.to_i}%)" })
      end
    end

    warnings
  end

  def overlapping_published_plan_year?
    self.employer_profile.plan_years.published_or_renewing_published.any? do |py|
      (py.start_on..py.end_on).cover?(self.start_on) && (py != self)
    end
  end

  # All active employees present on the roster with benefit groups belonging to this plan year
  def eligible_to_enroll
    return @eligible if defined? @eligible
    @eligible ||= find_census_employees.active
  end

  def waived
    return @waived if defined? @waived
    @waived ||= find_census_employees.waived
  end

  def waived_count
    waived.count
  end

  def covered
    return @covered if defined? @covered
    @covered ||= find_census_employees.covered
  end

  def find_census_employees
    return @census_employees if defined? @census_employees
    @census_employees ||= CensusEmployee.by_benefit_group_ids(benefit_group_ids)
  end

  def covered_count
    covered.count
  end

  def benefit_group_ids
    benefit_groups.collect(&:id)
  end

  def eligible_to_enroll_count
    eligible_to_enroll.size
  end

  # Employees who selected or waived and are not owners or direct family members of owners
  def non_business_owner_enrolled
    enrolled.select{|ce| !ce.is_business_owner}
  end

  # Any employee who selected or waived coverage
  def enrolled
    calc_active_health_assignments_for(eligible_to_enroll)
#    eligible_to_enroll.select{ |ce| ce.has_active_health_coverage?(self) }
  end

  def enrolled_by_bga
     candidate_benefit_group_assignments = eligible_to_enroll.map{|ce| enrolled_bga_for_ce(ce)}.compact
     enrolled_benefit_group_assignment_ids = HbxEnrollment.enrolled_shop_health_benefit_group_ids(candidate_benefit_group_assignments.map(&:id).uniq)
     bgas = candidate_benefit_group_assignments.select do |bga|
       enrolled_benefit_group_assignment_ids.include?(bga.id)
     end
  end

  def enrolled_bga_for_ce ce
     if is_renewing?
       ce.renewal_benefit_group_assignment
     else
       ce.active_benefit_group_assignment
     end
  end

  def calc_active_health_assignments_for(employee_pool)
    benefit_group_ids = self.benefit_groups.pluck(:_id)
    candidate_benefit_group_assignments = employee_pool.map do |ce|
        bg_assignment = nil
        bg_assignment = ce.active_benefit_group_assignment if benefit_group_ids.include?(ce.active_benefit_group_assignment.try(:benefit_group_id))
        bg_assignment = ce.renewal_benefit_group_assignment if benefit_group_ids.include?(ce.renewal_benefit_group_assignment.try(:benefit_group_id))
        bg_assignment ? [ce, bg_assignment] : nil
    end
    benefit_group_assignment_pairs = candidate_benefit_group_assignments.compact
    benefit_group_assignment_ids = benefit_group_assignment_pairs.map do |bgap|
      bgap.last._id
    end
    enrolled_benefit_group_assignment_ids = HbxEnrollment.enrolled_shop_health_benefit_group_ids(benefit_group_assignment_ids)
    have_shop_health_bgap = benefit_group_assignment_pairs.select do |bgap|
      enrolled_benefit_group_assignment_ids.include?(bgap.last.id)
    end
    have_shop_health_bgap.map(&:first)
  end

  def total_enrolled_count
    if self.employer_profile.census_employees.active.count <= Settings.aca.shop_market.small_market_active_employee_limit
      #enrolled.count
      enrolled_by_bga.count
    else
      0
    end
  end

  def enrollment_ratio
    if eligible_to_enroll_count == 0
      0
    else
      ((total_enrolled_count * 1.0)/ eligible_to_enroll_count)
    end
  end

  def minimum_enrolled_count
    (Settings.aca.shop_market.employee_participation_ratio_minimum * eligible_to_enroll_count).ceil
  end

  def additional_required_participants_count
    if total_enrolled_count < minimum_enrolled_count
      minimum_enrolled_count - total_enrolled_count
    else
      0.0
    end
  end

  def is_enrollment_valid?
    enrollment_errors.blank? ? true : false
  end

  def is_open_enrollment_closed?
    open_enrollment_end_on.end_of_day < TimeKeeper.date_of_record.beginning_of_day
  end

  def is_application_period_ended?
    start_on.beginning_of_day <= TimeKeeper.date_of_record.beginning_of_day
  end

  # Determine enrollment composition compliance with HBX-defined guards
  def enrollment_errors
    errors = {}

    # At least one employee must be enrollable.
    if eligible_to_enroll_count == 0
      errors.merge!(eligible_to_enroll_count: "at least one employee must be eligible to enroll")
    end

    # At least one employee who isn't an owner or family member of owner must enroll
    if non_business_owner_enrolled.count < eligible_to_enroll_count
      if non_business_owner_enrolled.count < Settings.aca.shop_market.non_owner_participation_count_minimum
        errors.merge!(non_business_owner_enrollment_count: "at least #{Settings.aca.shop_market.non_owner_participation_count_minimum} non-owner employee must enroll")
      end
    end

    # January 1 effective date exemption(s)
    unless effective_date.yday == 1
      # Verify ratio for minimum number of eligible employees that must enroll is met
      if enrollment_ratio < Settings.aca.shop_market.employee_participation_ratio_minimum
        errors.merge!(enrollment_ratio: "number of eligible participants enrolling (#{total_enrolled_count}) is less than minimum required #{eligible_to_enroll_count * Settings.aca.shop_market.employee_participation_ratio_minimum}")
      end
    end

    errors
  end

  def employees_are_matchable?
    %w(renewing_published renewing_enrolling renewing_enrollment_extended renewing_enrolled published enrolling enrollment_extended enrolled active).include? aasm_state
  end

  def application_warnings
    if !is_application_eligible?
      application_eligibility_warnings.each_pair(){ |key, value| self.errors.add(:base, value) }
    end
  end

  class << self
    def find(id)
      organizations = Organization.where("employer_profile.plan_years._id" => BSON::ObjectId.from_string(id))
      organizations.size > 0 ? organizations.first.employer_profile.plan_years.unscoped.detect { |py| py._id.to_s == id.to_s} : nil
    end

    def shop_enrollment_timetable(new_effective_date)
      effective_date = new_effective_date.to_date.beginning_of_month
      prior_month = effective_date - 1.month
      plan_year_start_on = effective_date
      plan_year_end_on = effective_date + 1.year - 1.day
      employer_initial_application_earliest_start_on = (effective_date + Settings.aca.shop_market.initial_application.earliest_start_prior_to_effective_on.months.months)
      employer_initial_application_earliest_submit_on = employer_initial_application_earliest_start_on
      employer_initial_application_latest_submit_on   = ("#{prior_month.year}-#{prior_month.month}-#{HbxProfile::ShopPlanYearPublishedDueDayOfMonth}").to_date
      open_enrollment_earliest_start_on     = effective_date - Settings.aca.shop_market.open_enrollment.maximum_length.months.months
      open_enrollment_latest_start_on       = ("#{prior_month.year}-#{prior_month.month}-#{HbxProfile::ShopOpenEnrollmentBeginDueDayOfMonth}").to_date
      open_enrollment_latest_end_on         = ("#{prior_month.year}-#{prior_month.month}-#{Settings.aca.shop_market.open_enrollment.monthly_end_on}").to_date
      binder_payment_due_date               = first_banking_date_prior ("#{prior_month.year}-#{prior_month.month}-#{Settings.aca.shop_market.binder_payment_due_on}")


      timetable = {
        effective_date: effective_date,
        plan_year_start_on: plan_year_start_on,
        plan_year_end_on: plan_year_end_on,
        employer_initial_application_earliest_start_on: employer_initial_application_earliest_start_on,
        employer_initial_application_earliest_submit_on: employer_initial_application_earliest_submit_on,
        employer_initial_application_latest_submit_on: employer_initial_application_latest_submit_on,
        open_enrollment_earliest_start_on: open_enrollment_earliest_start_on,
        open_enrollment_latest_start_on: open_enrollment_latest_start_on,
        open_enrollment_latest_end_on: open_enrollment_latest_end_on,
        binder_payment_due_date: binder_payment_due_date
      }

      timetable
    end

    def check_start_on(start_on)
      start_on = start_on.to_date
      shop_enrollment_times = shop_enrollment_timetable(start_on)

      if start_on.day != 1
        result = "failure"
        msg = "start on must be first day of the month"
      elsif TimeKeeper.date_of_record > shop_enrollment_times[:open_enrollment_latest_start_on]
        result = "failure"
        msg = "must choose a start on date #{(TimeKeeper.date_of_record - HbxProfile::ShopOpenEnrollmentBeginDueDayOfMonth + Settings.aca.shop_market.open_enrollment.maximum_length.months.months).beginning_of_month} or later"
      end
      {result: (result || "ok"), msg: (msg || "")}
    end

    def calculate_start_on_dates
      # Today - 5 + 2.months).beginning_of_month
      # July 6 => Sept 1
      # July 1 => Aug 1
      start_on = (TimeKeeper.date_of_record - HbxProfile::ShopOpenEnrollmentBeginDueDayOfMonth + Settings.aca.shop_market.open_enrollment.maximum_length.months.months).beginning_of_month
      end_on = (TimeKeeper.date_of_record - Settings.aca.shop_market.initial_application.earliest_start_prior_to_effective_on.months.months).beginning_of_month
      dates = (start_on..end_on).select {|t| t == t.beginning_of_month}
    end

    def calculate_start_on_options
      calculate_start_on_dates.map {|date| [date.strftime("%B %Y"), date.to_s(:db) ]}
    end

    def calculate_open_enrollment_date(start_on)
      start_on = start_on.to_date

      # open_enrollment_start_on = [start_on - 1.month, TimeKeeper.date_of_record].max
      # candidate_open_enrollment_end_on = Date.new(open_enrollment_start_on.year.to_i, open_enrollment_start_on.month.to_i, Settings.aca.shop_market.open_enrollment.monthly_end_on)

      # open_enrollment_end_on = if (candidate_open_enrollment_end_on - open_enrollment_start_on) < (Settings.aca.shop_market.open_enrollment.minimum_length.days - 1)
      #   candidate_open_enrollment_end_on.next_month
      # else
      #   candidate_open_enrollment_end_on
      # end

      open_enrollment_start_on = [(start_on - Settings.aca.shop_market.open_enrollment.maximum_length.months.months), TimeKeeper.date_of_record].max

      #candidate_open_enrollment_end_on = Date.new(open_enrollment_start_on.year, open_enrollment_start_on.month, Settings.aca.shop_market.open_enrollment.monthly_end_on)

      #open_enrollment_end_on = if (candidate_open_enrollment_end_on - open_enrollment_start_on) < (Settings.aca.shop_market.open_enrollment.minimum_length.days - 1)
      #  candidate_open_enrollment_end_on.next_month
      #else
      #  candidate_open_enrollment_end_on
      #end

      open_enrollment_end_on = shop_enrollment_timetable(start_on)[:open_enrollment_latest_end_on]

      binder_payment_due_date = map_binder_payment_due_date_by_start_on(start_on)

      {open_enrollment_start_on: open_enrollment_start_on,
       open_enrollment_end_on: open_enrollment_end_on,
       binder_payment_due_date: binder_payment_due_date}
    end

    def map_binder_payment_due_date_by_start_on(start_on)
      dates_map = {}
      {
        "2017-11-01" => '2017,10,12',
        "2017-12-01" => '2017,11,14',
        "2018-01-01" => '2017,12,12',
        "2018-02-01" => '2018,1,12',
        "2018-03-01" => '2018,2,13',
        "2018-04-01" => '2018,3,13',
        "2018-05-01" => '2018,4,12',
        "2018-06-01" => '2018,5,14',
        "2018-07-01" => '2018,6,12',
        "2018-08-01" => '2018,7,12',
        "2018-09-01" => '2018,8,14',
        "2018-10-01" => '2018,9,12',
        "2018-11-01" => '2018,10,12',
        "2018-12-01" => '2018,11,14',
        "2019-01-01" => '2018,12,12',
        "2019-02-01" => '2019,1,14',
        "2019-03-01" => '2019,2,12',
        "2019-04-01" => '2019,3,12',
        "2019-05-01" => '2019,4,12',
        "2019-06-01" => '2019,5,14',
        "2019-07-01" => '2019,6,12',
        "2019-08-01" => '2019,7,12',
        "2019-09-01" => '2019,8,13',
        "2019-10-01" => '2019,9,12',
        "2019-11-01" => '2019,10,15',
        "2019-12-01" => '2019,11,13',
        "2020-01-01" => '2020,12,12',
        "2020-02-01" => '2020,1,14',
        "2020-03-01" => '2020,2,12',
        "2020-04-01" => '2020,3,12',
        "2020-05-01" => '2020,4,14',
        "2020-06-01" => '2020,5,12',
        "2020-07-01" => '2020,6,12',
        "2020-08-01" => '2020,7,14',
        "2020-09-01" => '2020,8,12',
        "2020-10-01" => '2020,9,14',
        "2020-11-01" => '2020,10,14',
        "2020-12-01" => '2020,11,13',
        }.each_pair do |k, v|
          dates_map[k] = Date.strptime(v, '%Y,%m,%d')
        end

      dates_map[start_on.strftime('%Y-%m-%d')] || shop_enrollment_timetable(start_on)[:binder_payment_due_date]
    end

    ## TODO - add holidays
    def first_banking_date_prior(date_value)
      date = date_value.to_date
      date = date - 1 if date.saturday?
      date = date - 2 if date.sunday?
      date
    end

    def first_banking_date_after(date_value)
      date = date_value.to_date
      date = date + 2 if date.saturday?
      date = date + 1 if date.sunday?
      date
    end
  end


  aasm do
    state :draft, initial: true

    state :publish_pending      # Plan application as submitted has warnings
    state :eligibility_review   # Plan application was submitted with warning and is under review by HBX officials
    state :published,         :after_enter => [:accept_application, :link_census_employees]     # Plan is finalized. Employees may view benefits, but not enroll
    state :published_invalid, :after_enter => :decline_application    # Non-compliant plan application was forced-published

    state :enrolling, :after_enter => [:send_employee_invites, :link_census_employees]  # Published plan has entered open enrollment
    state :enrolled,  :after_enter => [:ratify_enrollment] # Published plan open enrollment has ended and is eligible for coverage,
    state :enrollment_extended                                                                      #   but effective date is in future
    state :application_ineligible, :after_enter => :deny_enrollment   # Application is non-compliant for enrollment
    state :expired              # Non-published plans are expired following their end on date
    state :canceled       # Published plan open enrollment has ended and is ineligible for coverage
    state :active               # Published plan year is in-force
    state :termination_pending

    state :renewing_draft
    state :renewing_published
    state :renewing_publish_pending
    state :renewing_enrolling, :after_enter => [:trigger_passive_renewals, :send_employee_invites]
    state :renewing_enrolled #:after_enter => :renewal_employer_open_enrollment_completed
    state :renewing_enrollment_extended
    state :renewing_application_ineligible, :after_enter => :deny_enrollment  # Renewal application is non-compliant for enrollment
    state :renewing_canceled

    state :suspended            # Premium payment is 61-90 days past due and coverage is currently not in effect
    state :terminated           # Coverage under this application is terminated
    state :conversion_expired   # Conversion employers who did not establish eligibility in a timely manner

    event :activate, :after => :record_transition do
      transitions from: [:published, :enrolling, :enrollment_extended, :enrolled, :renewing_published, :renewing_enrolling, :renewing_enrollment_extended, :renewing_enrolled],  to: :active,  :guard  => :can_be_activated?
    end

    event :expire, :after => :record_transition do
      transitions from: [:published, :enrolling, :enrolled, :active],  to: :expired,  :guard  => :can_be_expired?
    end

    # Time-based transitions: Change enrollment state, in-force plan year and clean house on any plan year applications from prior year
    event :advance_date, :after => :record_transition do
      transitions from: :enrolled,  to: :active,                  :guard  => :is_event_date_valid?
      transitions from: :published, to: :enrolling,               :guard  => :is_event_date_valid?
      transitions from: [:enrolling, :enrollment_extended], to: :enrolled,                :guards => [:is_open_enrollment_closed?, :is_enrollment_valid?]
      transitions from: [:enrolling, :enrollment_extended], to: :application_ineligible,  :guard => :is_open_enrollment_closed?
      # transitions from: :enrolling, to: :canceled,  :guard  => :is_open_enrollment_closed?, :after => :deny_enrollment  # Talk to Dan

      transitions from: :active, to: :terminated, :guard => :is_event_date_valid?
      transitions from: [:draft, :ineligible, :publish_pending, :published_invalid, :eligibility_review], to: :expired, :guard => :is_plan_year_end?

      transitions from: :renewing_enrolled,   to: :active,              :guard  => :is_event_date_valid?
      transitions from: :renewing_published,  to: :renewing_enrolling,  :guard  => :is_event_date_valid?
      transitions from: [:renewing_enrolling, :renewing_enrollment_extended],  to: :renewing_enrolled,   :guards => [:is_open_enrollment_closed?, :is_enrollment_valid?]
      transitions from: [:renewing_enrolling, :renewing_enrollment_extended],  to: :renewing_application_ineligible, :guard => :is_open_enrollment_closed?

      transitions from: :enrolling, to: :enrolling  # prevents error when plan year is already enrolling
    end

    ## Application eligibility determination process

    # Submit plan year application
    event :publish, :after => :record_transition do
      transitions from: :draft, to: :draft,     :guard => :is_application_unpublishable?
      transitions from: :draft, to: :enrolling, :guard => [:is_application_eligible?, :is_event_date_valid?], :after => :accept_application
      transitions from: :draft, to: :published, :guard => :is_application_eligible?
      transitions from: :draft, to: :publish_pending

      transitions from: :renewing_draft, to: :renewing_draft,     :guard => :is_application_unpublishable?
      transitions from: :renewing_draft, to: :renewing_enrolling, :guard => [:is_application_eligible?, :is_event_date_valid?], :after => :accept_application
      transitions from: :renewing_draft, to: :renewing_published, :guard => :is_application_eligible? 
      transitions from: :renewing_draft, to: :renewing_publish_pending
    end

    # Returns plan to draft state (or) renewing draft for edit
    event :withdraw_pending, :after => :record_transition do
      transitions from: :publish_pending, to: :draft
      transitions from: :renewing_publish_pending, to: :renewing_draft
    end

    # Plan as submitted failed eligibility check
    event :force_publish, :after => :record_transition do
      transitions from: :publish_pending, to: :published_invalid

      transitions from: :draft, to: :draft,     :guard => :is_application_invalid?
      transitions from: :draft, to: :enrolling, :guard => [:is_application_eligible?, :is_event_date_valid?], :after => :accept_application
      transitions from: :draft, to: :published, :guard => :is_application_eligible?
      transitions from: :draft, to: :publish_pending

      transitions from: :renewing_draft, to: :renewing_draft,     :guard => :is_application_invalid?
      transitions from: :renewing_draft, to: :renewing_enrolling, :guard => [:is_application_eligible?, :is_event_date_valid?], :after => :accept_application
      transitions from: :renewing_draft, to: :renewing_published, :guard => :is_application_eligible?
      transitions from: :renewing_draft, to: :renewing_publish_pending
    end

    # Employer requests review of invalid application determination
    event :request_eligibility_review, :after => :record_transition do
      transitions from: :published_invalid, to: :eligibility_review, :guard => :is_within_review_period?
    end

    # Upon review, application ineligible status overturned and deemed eligible
    event :grant_eligibility, :after => :record_transition do
      transitions from: :eligibility_review, to: :published
    end

    # Upon review, submitted application ineligible status verified ineligible
    event :deny_eligibility, :after => :record_transition do
      transitions from: :eligibility_review, to: :published_invalid
    end

    # Enrollment processed stopped due to missing binder payment
    event :cancel, :after => [:record_transition, :update_end_date, :notify_cancel_event] do
      transitions from: [:draft, :published, :publish_pending, :eligibility_review, :published_invalid, :application_ineligible, :enrolling, :enrolled, :active], to: :canceled, :after => [:cancel_employee_enrollments, :cancel_employee_benefit_packages]
    end

    # Coverage disabled due to non-payment
    event :suspend, :after => :record_transition do
      transitions from: :active, to: :suspended
    end

    # Scheduling terminations for plan years with a future end on date
    event :schedule_termination, :after => :record_transition do
      transitions from: :active,
                  to: :termination_pending
    end

    # Coverage terminated due to non-payment
    event :terminate, :after => :record_transition do
      transitions from: [:active, :suspended, :expired, :termination_pending], to: :terminated, :after => :terminate_employee_benefit_packages
    end

    # Coverage reinstated
    event :reinstate_plan_year, :after => :record_transition do
      transitions from: [:terminated,:termination_pending], to: :active, after: :reset_termination_and_end_date
    end

    event :renew_plan_year, :after => :record_transition do
      transitions from: :draft, to: :renewing_draft
    end

    event :renew_publish, :after => :record_transition do
      transitions from: :renewing_draft, to: :renewing_published
    end

    # Admin ability to reset plan year application
    event :revert_application, :after => :revert_employer_profile_application do
      transitions from: [
                            :enrolled, :enrolling, :active, :application_ineligible,
                            :renewing_application_ineligible, :published_invalid,
                            :eligibility_review, :published, :publish_pending
                          ], to: :draft, :after => [:cancel_enrollments]
    end

    # Admin ability to accept application and successfully complete enrollment
    event :enroll, :after => :record_transition do
      transitions from: [:published, :enrolling, :renewing_published], to: :enrolled
    end

    # Admin ability to reset renewing plan year application
    event :revert_renewal, :after => :record_transition do
      transitions from: [:active, :renewing_published, :renewing_enrolling,
        :renewing_application_ineligible, :renewing_enrolled], to: :renewing_draft, :after => [:cancel_enrollments]
    end

    event :cancel_renewal, :after => [:record_transition, :update_end_date, :notify_cancel_event] do
      transitions from: [:renewing_draft, :renewing_published, :renewing_enrolling, :renewing_application_ineligible, :renewing_enrolled, :renewing_publish_pending], to: :renewing_canceled, :after => [:cancel_employee_enrollments, :cancel_employee_benefit_packages]
    end

    event :conversion_expire, :after => :record_transition do
      transitions from: [:expired, :active], to: :conversion_expired, :guard => :can_be_migrated?
    end

    event :close_open_enrollment, :after => :record_transition do
      transitions from: [:enrolling, :enrollment_extended], to: :enrolled,                :guards => [:is_enrollment_valid?]
      transitions from: [:enrolling, :enrollment_extended], to: :application_ineligible

      transitions from: [:renewing_enrolling, :renewing_enrollment_extended],  to: :renewing_enrolled,   :guards => [:is_enrollment_valid?]
      transitions from: [:renewing_enrolling, :renewing_enrollment_extended],  to: :renewing_application_ineligible
    end

    event :extend_open_enrollment, :after => :record_transition do
      transitions from: [:canceled, :application_ineligible, :enrollment_extended, :enrolling], to: :enrollment_extended,                                     :guard => [:is_application_eligible?]
      transitions from: [:renewing_canceled, :renewing_application_ineligible, :renewing_enrollment_extended, :renewing_enrolling], to: :renewing_enrollment_extended, :guard => [:is_application_eligible?]
    end
  end

  def extend_open_enrollment(new_end_date = TimeKeeper.date_of_record)
    if may_extend_open_enrollment?
      self.update(:open_enrollment_end_on => new_end_date)
      self.extend_open_enrollment!
    end
  end

  def end_open_enrollment(end_date = nil)
    if may_close_open_enrollment?
      self.update(open_enrollment_end_on: end_date) if end_date.present?
      self.close_open_enrollment!
    end
  end

  def cancel_enrollments
    self.hbx_enrollments.each do |enrollment|
      enrollment.cancel_coverage! if enrollment.may_cancel_coverage?
    end
  end

  def set_plan_year_termination_date(end_on, options = {})
    self.end_on = end_on
    self.terminated_on = options[:terminated_on]
    self.termination_kind= options[:termination_kind]
  end

  def trigger_passive_renewals
    notify("acapi.info.events.plan_year.employee_passive_renewals_requested", {:plan_year_id => self.id.to_s})
  end

  def revert_employer_profile_application
    employer_profile.revert_application! if employer_profile.may_revert_application?
    record_transition
  end

  def adjust_open_enrollment_date
    if TimeKeeper.date_of_record > open_enrollment_start_on && TimeKeeper.date_of_record < open_enrollment_end_on
      update_attributes(:open_enrollment_start_on => TimeKeeper.date_of_record)
    end
  end

  def accept_application
    adjust_open_enrollment_date
    transition_success = employer_profile.application_accepted! if employer_profile.may_application_accepted?
  end

  def decline_application
    employer_profile.application_declined!
  end

  def ratify_enrollment
    employer_profile.enrollment_ratified! if employer_profile.may_enrollment_ratified?
  end

  def deny_enrollment
    if employer_profile.may_enrollment_denied?
      employer_profile.enrollment_denied!
    end
  end

  def is_eligible_to_match_census_employees?
    (benefit_groups.size > 0) and
    (published? or enrolling? or enrollment_extended? or enrolled? or active?)
  end

  def is_within_review_period?
    published_invalid? and
    (latest_workflow_state_transition.transition_at >
      (TimeKeeper.date_of_record - Settings.aca.shop_market.initial_application.appeal_period_after_application_denial.days))
  end

  def latest_workflow_state_transition
    workflow_state_transitions.order_by(:'transition_at'.desc).limit(1).first
  end

  def is_before_start?
    TimeKeeper.date_of_record.end_of_day < start_on
  end

  # Checks for external plan year
  def can_be_migrated?
    self.employer_profile.is_conversion? && self.is_conversion
  end

  def link_census_employees
    self.employer_profile.census_employees.eligible_without_term_pending.each do |census_employee|
      census_employee.save # This assigns default benefit package if none
    end
  end

  def send_employee_renewal_invites
    benefit_groups.each do |bg|
      bg.census_employees.non_terminated.each do |ce|
        Invitation.invite_renewal_employee!(ce)
      end
    end
  end

  def send_employee_initial_enrollment_invites
    benefit_groups.each do |bg|
      bg.census_employees.non_terminated.each do |ce|
        Invitation.invite_initial_employee!(ce)
      end
    end
  end

  def send_active_employee_invites
    benefit_groups.each do |bg|
      bg.census_employees.non_terminated.each do |ce|
        Invitation.invite_employee!(ce)
      end
    end
  end
  
  def notify_cancel_event(transmit_xml = false)
    return unless transmit_xml
    transition = self.latest_workflow_state_transition
    if TimeKeeper.date_of_record < start_on
      if transition.from_state == "enrolled" && open_enrollment_completed? && binder_paid? && past_transmission_threshold?
        notify_employer_py_cancellation
      elsif transition.from_state == "renewing_enrolled" && open_enrollment_completed? && past_transmission_threshold?
        notify_employer_py_cancellation
      end
    else
      if transition.from_state == "active"
        notify_employer_py_cancellation
      end
    end
  end

  alias_method :external_plan_year?, :can_be_migrated?

  private

  def notify_employer_py_cancellation
    notify(INITIAL_OR_RENEWAL_PLAN_YEAR_DROP_EVENT, {employer_id: self.employer_profile.hbx_id, plan_year_id: self.id.to_s, event_name: INITIAL_OR_RENEWAL_PLAN_YEAR_DROP_EVENT_TAG})
  end

  def notify_employer_py_terminate(transmit_xml)

    return unless transmit_xml
    return unless self.termination_pending? || self.terminated?

    if self.termination_kind == "voluntary"
      notify(VOLUNTARY_TERMINATED_PLAN_YEAR_EVENT, {employer_id: self.employer_profile.hbx_id, event_name: VOLUNTARY_TERMINATED_PLAN_YEAR_EVENT_TAG})
    end

    if self.termination_kind == "nonpayment"
      notify(NON_PAYMENT_TERMINATED_PLAN_YEAR_EVENT, {employer_id: self.employer_profile.hbx_id, event_name: NON_PAYMENT_TERMINATED_PLAN_YEAR_EVENT_TAG})
    end
  end

  def log_message(errors)
    msg = yield.first
    (errors[msg[0]] ||= []) << msg[1]
  end

  def can_be_expired?
    if PUBLISHED.include?(aasm_state) && TimeKeeper.date_of_record >= end_on
      true
    else
      false
    end
  end

  def can_be_activated?
    if (PUBLISHED + RENEWING_PUBLISHED_STATE).include?(aasm_state) && TimeKeeper.date_of_record >= start_on
      true
    else
      false
    end
  end

  def is_event_date_valid?
    today = TimeKeeper.date_of_record
    valid = case aasm_state
    when "published", "draft", "renewing_published", "renewing_draft"
      today >= open_enrollment_start_on
    when "enrolling", "renewing_enrolling"
      today > open_enrollment_end_on
    when "enrolled", "renewing_enrolled"
      today >= start_on
    when "active"
      today > end_on
    else
      false
    end

    valid
  end

  def is_plan_year_end?
    TimeKeeper.date_of_record.end_of_day == end_on
  end

  def record_transition
    self.workflow_state_transitions << WorkflowStateTransition.new(
      from_state: aasm.from_state,
      to_state: aasm.to_state,
      event: aasm.current_event
    )
  end

  def send_employee_invites
    return true if benefit_groups.any?{|bg| bg.is_congress?}
    if is_renewing?
      notify("acapi.info.events.plan_year.employee_renewal_invitations_requested", {:plan_year_id => self.id.to_s})
    elsif enrolling?
      notify("acapi.info.events.plan_year.employee_initial_enrollment_invitations_requested", {:plan_year_id => self.id.to_s})
    else
      notify("acapi.info.events.plan_year.employee_enrollment_invitations_requested", {:plan_year_id => self.id.to_s})
    end
  end

  def within_review_period?
    (latest_workflow_state_transition.transition_at.end_of_day + Settings.aca.shop_market.initial_application.appeal_period_after_application_denial.days) > TimeKeeper.date_of_record
  end

  def duration_in_days(duration)
    (duration / 1.day).to_i
  end

  def open_enrollment_date_checks
    return if canceled? || expired? || renewing_canceled? || enrollment_extended? || renewing_enrollment_extended?
    return if start_on.blank? || end_on.blank? || open_enrollment_start_on.blank? || open_enrollment_end_on.blank?
    return if imported_plan_year

    if start_on != start_on.beginning_of_month
      errors.add(:start_on, "must be first day of the month")
    end

    if end_on > start_on.years_since(Settings.aca.shop_market.benefit_period.length_maximum.year)
      errors.add(:end_on, "benefit period may not exceed #{Settings.aca.shop_market.benefit_period.length_maximum.year} year")
    end

    if open_enrollment_end_on > start_on
      errors.add(:start_on, "can't occur before open enrollment end date")
    end

    if open_enrollment_end_on < open_enrollment_start_on
      errors.add(:open_enrollment_end_on, "can't occur before open enrollment start date")
    end

    if open_enrollment_start_on < (start_on - Settings.aca.shop_market.open_enrollment.maximum_length.months.months)
      errors.add(:open_enrollment_start_on, "can't occur before 60 days before start date")
    end

    if open_enrollment_end_on > (open_enrollment_start_on + Settings.aca.shop_market.open_enrollment.maximum_length.months.months)
      errors.add(:open_enrollment_end_on, "open enrollment period is greater than maximum: #{Settings.aca.shop_market.open_enrollment.maximum_length.months} months")
    end

    if (start_on + Settings.aca.shop_market.initial_application.earliest_start_prior_to_effective_on.months.months) > TimeKeeper.date_of_record
      errors.add(:start_on, "may not start application before " \
                 "#{(start_on + Settings.aca.shop_market.initial_application.earliest_start_prior_to_effective_on.months.months).to_date} with #{start_on} effective date")
    end

    if !['canceled', 'suspended', 'terminated', 'termination_pending', 'renewing_canceled'].include?(aasm_state)

      #groups terminated for non-payment get 31 more days of coverage from their paid through date
      if end_on != end_on.end_of_month
        errors.add(:end_on, "must be last day of the month")
      end

      if end_on != (start_on + Settings.aca.shop_market.benefit_period.length_minimum.year.years - 1.day)
        errors.add(:end_on, "plan year period should be: #{duration_in_days(Settings.aca.shop_market.benefit_period.length_minimum.year.years - 1.day)} days")
      end
    end
  end

  def reset_termination_and_end_date
    update_attributes!({terminated_on: nil, end_on: start_on.next_year.prev_day})
  end
end
