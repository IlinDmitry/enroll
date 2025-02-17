class BenefitGroup
  include Mongoid::Document
  include Mongoid::Timestamps
  include ::Eligibility::BenefitGroup
  include Config::AcaModelConcern

  embedded_in :plan_year

  attr_accessor :metal_level_for_elected_plan, :carrier_for_elected_plan

  PLAN_OPTION_KINDS = %w(single_plan single_carrier metal_level)
  EFFECTIVE_ON_KINDS = %w(date_of_hire first_of_month)
  OFFSET_KINDS = [0, 1, 30, 60]
  TERMINATE_ON_KINDS = %w(end_of_month)
  PERSONAL_RELATIONSHIP_KINDS = [
    :employee,
    :spouse,
    :domestic_partner,
    :child_under_26,
    :child_26_and_over
  ]

  field :title, type: String, default: ""
  field :description, type: String, default: ""
  field :effective_on_kind, type: String, default: "first_of_month"
  field :terminate_on_kind, type: String, default: "end_of_month"
  field :dental_plan_option_kind, type: String
  field :plan_option_kind, type: String
  field :default, type: Boolean, default: false

  field :contribution_pct_as_int, type: Integer, default: 0
  field :employee_max_amt, type: Money, default: 0
  field :first_dependent_max_amt, type: Money, default: 0
  field :over_one_dependents_max_amt, type: Money, default: 0

  # Number of days following date of hire
  field :effective_on_offset, type: Integer, default: 0

  # Non-congressional
  # belongs_to :reference_plan, class_name: "Plan"
  field :reference_plan_id, type: BSON::ObjectId
  field :lowest_cost_plan_id, type: BSON::ObjectId
  field :highest_cost_plan_id, type: BSON::ObjectId

  # Employer contribution amount as percentage of reference plan premium
  field :employer_max_amt_in_cents, type: Integer, default: 0

  # Employer dental plan_ids
  field :dental_relationship_benefits_attributes_time, type: BSON::ObjectId, default: 0
  field :dental_reference_plan_id, type: BSON::ObjectId
  field :elected_dental_plan_ids, type: Array, default: []

  # Array of plan_ids
  field :elected_plan_ids, type: Array, default: []
  field :is_congress, type: Boolean, default: false
  field :_type, type: String, default: self.name

  field :is_active, type: Boolean, default: true

  default_scope ->{ where(is_active: true) }

  delegate :start_on, :end_on, to: :plan_year
  # accepts_nested_attributes_for :plan_year

  delegate :employer_profile, to: :plan_year, allow_nil: true

  embeds_many :relationship_benefits, cascade_callbacks: true
  accepts_nested_attributes_for :relationship_benefits, reject_if: :all_blank, allow_destroy: true

  embeds_many :dental_relationship_benefits, cascade_callbacks: true
  accepts_nested_attributes_for :dental_relationship_benefits, reject_if: :all_blank, allow_destroy: true

  field :carrier_for_elected_dental_plan, type: BSON::ObjectId

  attr_accessor :metal_level_for_elected_plan, :carrier_for_elected_plan, :carrier_for_elected_dental_plan

  #TODO add following attributes: :title,
  validates_presence_of :relationship_benefits, :effective_on_kind, :terminate_on_kind, :effective_on_offset,
                        :reference_plan_id, :plan_option_kind, :elected_plan_ids

  validates_uniqueness_of :title

  validates :plan_option_kind,
    allow_blank: false,
    inclusion: {
      in: PLAN_OPTION_KINDS,
      message: "%{value} is not a valid plan option kind"
    }

  validates :effective_on_kind,
    allow_blank: false,
    inclusion: {
      in: EFFECTIVE_ON_KINDS,
      message: "%{value} is not a valid effective date kind"
    }

  validates :effective_on_offset,
    allow_blank: false,
    inclusion: {
      in: OFFSET_KINDS,
      message: "%{value} is not a valid effective date offset kind"
    }

  validate :plan_integrity
  validate :check_employer_contribution_for_employee
  validate :check_offered_for_employee

  before_save :set_congress_defaults

  # def plan_option_kind=(new_plan_option_kind)
  #   super new_plan_option_kind.to_s
  # end

  alias_method :is_congress?, :is_congress

  def reference_plan=(new_reference_plan)
    raise ArgumentError.new("expected Plan") unless new_reference_plan.is_a? Plan
    self.reference_plan_id = new_reference_plan._id
    @reference_plan = new_reference_plan
  end

  def dental_reference_plan=(new_reference_plan)
    raise ArgumentError.new("expected Plan") unless new_reference_plan.is_a? Plan
    self.dental_reference_plan_id = new_reference_plan._id
    @dental_reference_plan = new_reference_plan
  end

  def reference_plan
    return @reference_plan if defined? @reference_plan
    @reference_plan = Plan.find(reference_plan_id) unless reference_plan_id.nil?
  end

  def dental_reference_plan
    return @dental_reference_plan if defined? @dental_reference_plan
    @dental_reference_plan = Plan.find(dental_reference_plan_id) if dental_reference_plan_id.present?
  end

  def is_offering_dental?
    dental_reference_plan_id.present? && elected_dental_plan_ids.any?
  end

  def is_open_enrollment?
    plan_year.open_enrollment_contains?(TimeKeeper.date_of_record)
  end

  def termination_effective_on_for(new_date)
    if plan_year.open_enrollment_contains?(new_date) || new_date < plan_year.start_on
      plan_year.start_on
    else
      new_date.end_of_month if terminate_on_kind == "end_of_month"
    end
  end

  # def set_bounding_cost_plans
  #   plans = Plan.shop_health_by_active_year(reference_plan.active_year).by_health_metal_levels([reference_plan.metal_level])
  #   if plans.size > 0
  #     plans_by_cost = plans.sort_by { |plan| plan.premium_tables.first.cost }

  #     self.lowest_cost_plan_id  = plans_by_cost.first.id
  #     @lowest_cost_plan = plans_by_cost.first

  #     self.highest_cost_plan_id = plans_by_cost.last.id
  #     @highest_cost_plan = plans_by_cost.last
  #   end
  # end


  def set_bounding_cost_plans
    return if reference_plan_id.nil?

    if plan_option_kind == "single_plan"
      plans = [reference_plan]
    else
      if plan_option_kind == "single_carrier"
        plans = Plan.shop_health_by_active_year(reference_plan.active_year).by_carrier_profile(reference_plan.carrier_profile)
      else
        plans = Plan.shop_health_by_active_year(reference_plan.active_year).by_health_metal_levels([reference_plan.metal_level])
      end
    end

    set_lowest_and_highest(plans)
  end

  def set_bounding_cost_dental_plans
    return if reference_plan_id.nil?

    if dental_plan_option_kind == "single_plan"
      plans = elected_dental_plans
    elsif dental_plan_option_kind == "single_carrier"
      plans = Plan.shop_dental_by_active_year(reference_plan.active_year).by_carrier_profile(reference_plan.carrier_profile)
    end

    set_lowest_and_highest(plans)
  end

  def set_lowest_and_highest(plans)
    if plans.size > 0
      plans_by_cost = plans.sort_by { |plan| plan.premium_tables.first.cost }

      self.lowest_cost_plan_id  = plans_by_cost.first.id
      @lowest_cost_plan = plans_by_cost.first

      self.highest_cost_plan_id = plans_by_cost.last.id
      @highest_cost_plan = plans_by_cost.last
    end
  end

  def lowest_cost_plan
    return @lowest_cost_plan if defined? @lowest_cost_plan
  end

  def highest_cost_plan
    return @highest_cost_plan if defined? @highest_cost_plan
  end

  def elected_plans=(new_plans)
    return unless new_plans.present?

    if new_plans.is_a? Array
      self.elected_plan_ids = new_plans.reduce([]) { |list, plan| list << plan._id }
    else
      self.elected_plan_ids = Array.new(1, new_plans.try(:_id))
    end

    set_bounding_cost_plans
    @elected_plans = new_plans
  end

  def elected_dental_plans=(new_plans)
    return unless new_plans.present?
    self.elected_dental_plan_ids = new_plans.reduce([]) { |list, plan| list << plan._id }

    # set_bounding_cost_plans
    @elected_dental_plans = new_plans
  end

  def elected_plans
    return @elected_plans if defined? @elected_plans
    @elected_plans ||= Plan.where(:id => {"$in" => elected_plan_ids}).to_a
  end

  def elected_dental_plans
    return @elected_dental_plans if defined? @elected_dental_plans
    @elected_dental_plans ||= Plan.where(:id => {"$in" => elected_dental_plan_ids}).to_a
  end

  def decorated_elected_plans(member_provider, coverage_kind="")
    max_contribution_cache = Hash.new
    get_elected_plans = (coverage_kind == "health" ? elected_plans : elected_dental_plans)
    ref_plan = (coverage_kind == "health" ? reference_plan : dental_reference_plan)
    get_elected_plans.collect(){|plan| decorated_plan(plan, member_provider, ref_plan, max_contribution_cache)}
  end

  def decorated_plan(plan, member_provider, ref_plan, max_contribution_cache = {})
    if is_congress
      PlanCostDecoratorCongress.new(plan, member_provider, self, max_contribution_cache)
    else
      PlanCostDecorator.new(plan, member_provider, self, ref_plan, max_contribution_cache)
    end
  end

  def benefit_group_assignments
    BenefitGroupAssignment.by_benefit_group_id(id)
  end

  def census_employees
    CensusEmployee.find_all_by_benefit_group(self)
  end

  def assignable_to?(census_employee)
    return !(census_employee.employment_terminated_on < start_on || census_employee.hired_on > end_on)
  end

  def employer_max_amt_in_cents=(new_employer_max_amt_in_cents)
    write_attribute(:employer_max_amt_in_cents, dollars_to_cents(new_employer_max_amt_in_cents))
  end

  def premium_in_dollars
    cents_to_dollars(employer_max_amt_in_cents)
  end

  def relationship_benefit_for(relationship)
    relationship_benefits.where(relationship: relationship).first
  end

  def dental_relationship_benefit_for(relationship)
    dental_relationship_benefits.where(relationship: relationship).first
  end

  def build_relationship_benefits
    self.relationship_benefits = PERSONAL_RELATIONSHIP_KINDS.map do |relationship|
       self.relationship_benefits.build(relationship: relationship, offered: true)
    end
  end

  def build_dental_relationship_benefits
    self.dental_relationship_benefits = PERSONAL_RELATIONSHIP_KINDS.map do |relationship|
       self.dental_relationship_benefits.build(relationship: relationship, offered: true)
    end
  end

  def simple_benefit_list(employee_premium_pct, dependent_premium_pct, employer_max_amount)
    [
      RelationshipBenefit.new(benefit_group: self,
                              relationship: :employee,
                              premium_pct: employee_premium_pct,
                              employer_max_amt: employer_max_amount,
                              offered: true),
    ] + PERSONAL_RELATIONSHIP_KINDS.dup.delete_if{|kind| [:employee, :child_26_and_over].include?(kind)}.collect do |relationship|
      RelationshipBenefit.new(benefit_group: self,
                              relationship: relationship,
                              premium_pct: dependent_premium_pct,
                              employer_max_amt: employer_max_amount,
                              offered: true)
    end + [
      RelationshipBenefit.new(benefit_group: self,
                              relationship: :child_26_and_over,
                              premium_pct: employee_premium_pct,
                              employer_max_amt: employer_max_amount,
                              offered: false),
    ]
  end

  def self.find(id)
    ::Caches::RequestScopedCache.lookup(:employer_calculation_cache_for_benefit_groups, id) do
      if organization = Organization.unscoped.where({"employer_profile.plan_years.benefit_groups._id" => id }).first
        plan_year = organization.employer_profile.plan_years.where({"benefit_groups._id" => id }).first
        plan_year.benefit_groups.unscoped.detect{|bg| bg.id == id }
      else
        nil
      end
    end
  end

  def monthly_employer_contribution_amount(plan = reference_plan)
    return 0 if targeted_census_employees.count > 199
    targeted_census_employees.active.collect do |ce|
      if plan.coverage_kind == 'dental' && self.persisted?
        pcd = PlanCostDecorator.new(plan, ce, self, dental_reference_plan)
      else
        pcd = PlanCostDecorator.new(plan, ce, self, reference_plan)
      end
      pcd.total_employer_contribution
    end.sum
  end

  def monthly_min_employee_cost(coverage_kind = nil)
    return 0 if targeted_census_employees.count > 199
    targeted_census_employees.active.collect do |ce|
      if coverage_kind == 'dental'
        pcd = PlanCostDecorator.new(dental_reference_plan, ce, self, dental_reference_plan)
      else
        pcd = PlanCostDecorator.new(reference_plan, ce, self, reference_plan)
      end
      pcd.total_employee_cost
    end.min
  end

  def monthly_max_employee_cost(coverage_kind = nil)
    return 0 if targeted_census_employees.count > 199
    targeted_census_employees.active.collect do |ce|
      if coverage_kind == 'dental'
        pcd = PlanCostDecorator.new(dental_reference_plan, ce, self, dental_reference_plan)
      else
        pcd = PlanCostDecorator.new(reference_plan, ce, self, reference_plan)
      end
      pcd.total_employee_cost
    end.max
  end

  def targeted_census_employees
    target_object = persisted? ? self : plan_year.employer_profile
    target_object.census_employees
  end

  def employee_cost_for_plan(ce, plan = reference_plan)
    pcd = @is_congress ? decorated_plan(plan, ce) : PlanCostDecorator.new(plan, ce, self, reference_plan)
    pcd.total_employee_cost
  end

  def sole_source?
    plan_option_kind == "sole_source"
  end

  def single_plan_type?
    plan_option_kind == "single_plan"
  end

  def is_default?
    default
  end

  def carriers_offered
    case plan_option_kind
    when "single_plan"
      Plan.where(id: reference_plan_id).pluck(:carrier_profile_id)
    when "single_carrier"
      Plan.where(id: reference_plan_id).pluck(:carrier_profile_id)
    when "metal_level"
      Plan.where(:id => {"$in" => elected_plan_ids}).pluck(:carrier_profile_id).uniq
    end
  end

  def dental_carriers_offered
    return [] unless is_offering_dental?
    if dental_plan_option_kind == 'single_plan'
      Plan.where(:id => {"$in" => elected_dental_plan_ids}).pluck(:carrier_profile_id).uniq
    else
      Plan.where(id: dental_reference_plan_id).pluck(:carrier_profile_id)
    end
  end

  def elected_plans_by_option_kind
    if constrain_service_areas?
      @profile_and_service_area_pairs = CarrierProfile.carrier_profile_service_area_pairs_for(employer_profile, self.start_on.year)
    end
    case plan_option_kind
    when "sole_source"
      Plan.where(id: reference_plan_id).first
    when "single_plan"
      Plan.where(id: reference_plan_id).first
    when "single_carrier"
      if carrier_for_elected_plan.blank?
        @carrier_for_elected_plan = reference_plan.carrier_profile_id if reference_plan.present?
      end
      carrier_profile_id = reference_plan.carrier_profile_id

      if constrain_service_areas?
        plans = Plan.check_plan_offerings_for_single_carrier # filter by vertical choice(as there should be no bronze plans for one carrier.)
        plans.valid_shop_health_plans_for_service_area("carrier", carrier_for_elected_plan, start_on.year, @profile_and_service_area_pairs.select {|pair| pair.first == carrier_profile_id}).to_a
      else
        Plan.valid_shop_health_plans("carrier", carrier_for_elected_plan, start_on.year).to_a
      end
    when "metal_level"
      metal_level_for_elected_plan = reference_plan.metal_level if metal_level_for_elected_plan.blank?

      if constrain_service_areas?
        Plan.valid_shop_health_plans_for_service_area("metal_level", metal_level_for_elected_plan, start_on.year, @profile_and_service_area_pairs).to_a
      else
        Plan.valid_shop_health_plans("metal_level", metal_level_for_elected_plan, start_on.year).to_a
      end
    end
  end

  def elected_dental_plans_by_option_kind
    if dental_plan_option_kind == "single_carrier"
      Plan.by_active_year(self.start_on.year).shop_market.dental_coverage.by_carrier_profile(self.carrier_for_elected_dental_plan)
    else
      Plan.by_active_year(self.start_on.year).shop_market.dental_coverage
    end
  end

  def effective_title_by_offset
    case effective_on_offset
    when 0
      "First of the month following or coinciding with date of hire"
    when 1
      "First of the month following date of hire"
    when 30
      "First of the month following 30 days"
    when 60
      "First of the month following 60 days"
    end
  end

  def disable_benefits
    self.employer_profile.census_employees.each do |ce|
      benefit_group_assignments = ce.benefit_group_assignments.where(benefit_group_id: self.id)

      if benefit_group_assignments.present?
        benefit_group_assignments.each do |bga|
          bga.hbx_enrollments.each do |enrollment|
            enrollment.cancel_coverage! if enrollment.may_cancel_coverage?
          end
          bga.update(is_active: false) unless self.plan_year.is_renewing?
        end

        other_benefit_group = self.plan_year.benefit_groups.detect{ |bg| bg.id != self.id}

        if self.plan_year.is_renewing?
          ce.add_renew_benefit_group_assignment(other_benefit_group)
        else
          ce.find_or_create_benefit_group_assignment([other_benefit_group])
        end
      end
    end

    self.is_active = false
  end

  def renewal_elected_plan_ids
    start_on_year = (start_on.next_year).year
    if plan_option_kind == "single_carrier"
      Plan.by_active_year(start_on_year).shop_market.health_coverage.by_carrier_profile(reference_plan.carrier_profile).and(hios_id: /-01/).pluck(:_id)
    else
      if plan_option_kind == "metal_level"
        Plan.by_active_year(start_on_year).shop_market.health_coverage.by_metal_level(reference_plan.metal_level).and(hios_id: /-01/).pluck(:_id)
      else
        Plan.where(:id.in => elected_plan_ids).pluck(:renewal_plan_id).compact
      end
    end
  end

  def renewal_elected_dental_plan_ids
    return [] unless is_offering_dental?
    start_on_year = (start_on.next_year).year
    if plan_option_kind == "single_carrier"
      Plan.by_active_year(start_on_year).shop_market.dental_coverage.by_carrier_profile(dental_reference_plan.carrier_profile).pluck(:_id)
    else
      Plan.where(:id.in => elected_dental_plan_ids).pluck(:renewal_plan_id).compact
    end
  end

  private

  def set_congress_defaults
    return true unless is_congress
    self.plan_option_kind = "metal_level"
    self.default = true

    # 2018 contribution schedule
    self.contribution_pct_as_int   = 75
    self.employee_max_amt = 498.72 if employee_max_amt == 0
    self.first_dependent_max_amt = 1066.59 if first_dependent_max_amt == 0
    self.over_one_dependents_max_amt = 1138.19 if over_one_dependents_max_amt == 0
  end

  def dollars_to_cents(amount_in_dollars)
    Rational(amount_in_dollars) * Rational(100) if amount_in_dollars
  end

  def cents_to_dollars(amount_in_cents)
    (Rational(amount_in_cents) / Rational(100)).to_f if amount_in_cents
  end

  def is_eligible_to_enroll_on?(date_of_hire, enrollment_date = TimeKeeper.date_of_record)

    # Length of time prior to effective date that EE may purchase plan
    Settings.aca.shop_market.earliest_enroll_prior_to_effective_on.days

    # Length of time following effective date that EE may purchase plan
    Settings.aca.shop_market.latest_enroll_after_effective_on.days

    # Length of time that EE may enroll following correction to Census Employee Identifying info
    Settings.aca.shop_market.latest_enroll_after_employee_roster_correction_on.days

  end

  # Non-congressional
  # pick reference plan
  # two pctages
  # toward employee
  # toward each dependent type

  # member level premium in reference plan, apply pctage by type, calc $$ amount.
  # may be applied toward and other offered plan
  # never pay more than premium per person
  # extra may not be applied toward other members

  def plan_integrity
    return if elected_plan_ids.blank?

    if (plan_option_kind == "single_plan") && (elected_plan_ids.first != reference_plan_id)
      self.errors.add(:elected_plans, "single plan must be the reference plan")
    end

    if (plan_option_kind == "single_carrier")
      if !(elected_plan_ids.include? reference_plan_id)
        self.errors.add(:elected_plans, "single carrier must include reference plan")
      end
      if elected_plans.detect { |plan| plan.carrier_profile_id != reference_plan.try(:carrier_profile_id) }
        self.errors.add(:elected_plans, "not all from the same carrier as reference plan")
      end
    end

    if (plan_option_kind == "metal_level") && !(elected_plan_ids.include? reference_plan_id)
      self.errors.add(:elected_plans, "not all of the same metal level as reference plan")
    end
  end

  def check_employer_contribution_for_employee
    start_on = self.plan_year.try(:start_on)
    return if start_on.try(:at_beginning_of_year) == start_on

    # all employee contribution < 50% for 1/1 employers
    if start_on.month == 1 && start_on.day == 1
    else
      if relationship_benefits.present? && (relationship_benefits.find_by(relationship: "employee").try(:premium_pct) || 0) < Settings.aca.shop_market.employer_contribution_percent_minimum
        self.errors.add(:relationship_benefits, "Employer contribution must be ≥ 50% for employee")
      end
    end
  end

  def check_offered_for_employee
    if relationship_benefits.present? && (relationship_benefits.find_by(relationship: "employee").try(:offered) != true)
      self.errors.add(:relationship_benefits, "employee must be offered")
    end
  end
end
