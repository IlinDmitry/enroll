require 'rails_helper'

describe PlanYear, :type => :model, :dbclean => :after_each do
  it { should validate_presence_of :start_on }
  it { should validate_presence_of :end_on }
  it { should validate_presence_of :open_enrollment_start_on }
  it { should validate_presence_of :open_enrollment_end_on }

  let!(:employer_profile)               { FactoryGirl.create(:employer_profile) }
  let(:valid_plan_year_start_on)        { TimeKeeper.date_of_record.end_of_month + 1.day + 1.month }
  let(:valid_plan_year_end_on)          { (valid_plan_year_start_on + 1.year - 1.day).end_of_month }
  let(:valid_open_enrollment_start_on)  { valid_plan_year_start_on.prev_month }
  let(:valid_open_enrollment_end_on)    { valid_open_enrollment_start_on + 9.days }
  let(:valid_fte_count)                 { 5 }
  let(:max_fte_count)                   { Settings.aca.shop_market.small_market_employee_count_maximum }
  let(:invalid_fte_count)               { Settings.aca.shop_market.small_market_employee_count_maximum + 1 }

  let(:valid_params) do
    {
      employer_profile: employer_profile,
      start_on: valid_plan_year_start_on,
      end_on: valid_plan_year_end_on,
      open_enrollment_start_on: valid_open_enrollment_start_on,
      open_enrollment_end_on: valid_open_enrollment_end_on,
      fte_count: valid_fte_count
    }
  end

  before do
    TimeKeeper.set_date_of_record_unprotected!(Date.current)
    allow_any_instance_of(CensusEmployee).to receive(:generate_and_deliver_checkbook_url).and_return(true)
  end

  context ".new" do
    context "with no arguments" do
      let(:params) {{}}

      it "should not save" do
        expect(PlanYear.new(**params).save).to be_falsey
      end
    end

    context "with no employer profile" do
      let(:params) {valid_params.except(:employer_profile)}

      it "should raise" do
        expect{PlanYear.create(**params)}.to raise_error(Mongoid::Errors::NoParent)
      end
    end

    context "with no start on" do
      let(:params) {valid_params.except(:start_on)}

      it "should fail validation" do
        expect(PlanYear.create(**params).errors[:start_on].any?).to be_truthy
      end
    end

    context "with no end on" do
      let(:params) {valid_params.except(:end_on)}

      it "should fail validation" do
        expect(PlanYear.create(**params).errors[:end_on].any?).to be_truthy
      end
    end

    context "with no open enrollment start on" do
      let(:params) {valid_params.except(:open_enrollment_start_on)}

      it "should fail validation" do
        expect(PlanYear.create(**params).errors[:open_enrollment_start_on].any?).to be_truthy
      end
    end

    context "with no open enrollment end on" do
      let(:params) {valid_params.except(:open_enrollment_end_on)}

      it "should fail validation" do
        expect(PlanYear.create(**params).errors[:open_enrollment_end_on].any?).to be_truthy
      end
    end

    context "with all valid arguments" do
      let(:params) { valid_params }
      let(:plan_year) { PlanYear.new(**params) }

      it "should be valid" do
        expect(plan_year.valid?).to be_truthy
      end

      it "should save" do
        expect(plan_year.save).to be_truthy
      end

      context "and it is saved" do
        let!(:saved_plan_year) do
          py = plan_year
          py.save
          py
        end

        it "should be findable" do
          expect(PlanYear.find(saved_plan_year.id).id.to_s).to eq saved_plan_year.id.to_s
        end
      end
    end
  end

  context "a new plan year is initialized" do
    let(:plan_year) { PlanYear.new(**valid_params) }

    it "contains the correct renewing states" do
      expect(PlanYear::RENEWING).to eq %w(renewing_draft renewing_published renewing_enrolling renewing_enrollment_extended renewing_enrolled renewing_publish_pending)
    end

    it "census employees should not be matchable" do
      expect(plan_year.is_eligible_to_match_census_employees?).to be_falsey
    end

    context "and effective date is specified and effective date doesn't provide enough time for enrollment" do
      let(:prior_month_open_enrollment_start)  { TimeKeeper.date_of_record.beginning_of_month + Settings.aca.shop_market.open_enrollment.monthly_end_on - Settings.aca.shop_market.open_enrollment.minimum_length.days - 1.day}
      let(:invalid_effective_date)   { (prior_month_open_enrollment_start + 1.month).beginning_of_month }
      before do
        plan_year.effective_date = invalid_effective_date
        plan_year.end_on = invalid_effective_date + Settings.aca.shop_market.benefit_period.length_minimum.year.years - 1.day
      end

      context "and an employer is submitting the effective date" do
        it "should be invalid" do
          expect(plan_year.valid?).to be_falsey
        end
      end

      context "and an HbxAdmin or system service is submitting the effective date" do
        # TODO: how do we know an HbxAdmin is making the change at the model level?
        it "should be valid"
      end
    end

    context "and effective date is specified and effective date does provide enough time for enrollment" do
      let(:prior_month_open_enrollment_start)  { TimeKeeper.date_of_record.beginning_of_month + Settings.aca.shop_market.open_enrollment.monthly_end_on - Settings.aca.shop_market.open_enrollment.minimum_length.days - 1.day}
      let(:valid_effective_date)   { (prior_month_open_enrollment_start + 3.months).beginning_of_month }
      before do
        plan_year.effective_date = valid_effective_date
        plan_year.end_on = valid_effective_date + Settings.aca.shop_market.benefit_period.length_minimum.year.years - 1.day
      end

      it "should be valid" do
        expect(plan_year.valid?).to be_truthy
      end

    end

    context "and an open enrollment period is specified" do
      context "and open enrollment start date is after the end date" do
        let(:open_enrollment_end_on)    { TimeKeeper.date_of_record }
        let(:open_enrollment_start_on)  { open_enrollment_end_on + 1 }

        before do
          plan_year.open_enrollment_start_on = open_enrollment_start_on
          plan_year.open_enrollment_end_on = open_enrollment_end_on
        end

        it "should fail validation" do
          expect(plan_year.valid?).to be_falsey
          expect(plan_year.errors[:open_enrollment_end_on].any?).to be_truthy
        end
      end

      context "and the open enrollment period is too long" do
        let(:open_enrollment_start_on)  { TimeKeeper.date_of_record }
        let(:open_enrollment_end_on)    { open_enrollment_start_on + Settings.aca.shop_market.open_enrollment.maximum_length.months.months + 1.day }

        before do
          plan_year.open_enrollment_start_on = open_enrollment_start_on
          plan_year.open_enrollment_end_on = open_enrollment_end_on
        end

        it "should fail validation" do
          expect(plan_year.valid?).to be_falsey
          expect(plan_year.errors[:open_enrollment_end_on].any?).to be_truthy
        end
      end

      context "and a plan year start and end is specified" do
        context "and the plan year start date isn't first day of month" do
          let(:start_on)  { TimeKeeper.date_of_record.beginning_of_month + 1 }
          let(:end_on)    { start_on + Settings.aca.shop_market.benefit_period.length_minimum.year.years - 1.day }

          before do
            plan_year.start_on = start_on
            plan_year.end_on = end_on
          end

          it "should fail validation" do
            expect(plan_year.valid?).to be_falsey
            expect(plan_year.errors[:start_on].any?).to be_truthy
          end
        end

        context "and the plan year start date is after the end date" do
          let(:end_on)    { TimeKeeper.date_of_record.beginning_of_month }
          let(:start_on)  { end_on + 1 }

          before do
            plan_year.start_on = start_on
            plan_year.end_on = end_on
          end

          it "should fail validation" do
            expect(plan_year.valid?).to be_falsey
            expect(plan_year.errors[:end_on].any?).to be_truthy
          end
        end

        context "and the plan year period is too short" do
          let(:invalid_length)  { Settings.aca.shop_market.benefit_period.length_minimum.year.years - 2.days }
          let(:start_on)  { TimeKeeper.date_of_record.end_of_month + 1 }
          let(:end_on)    { start_on + invalid_length }

          before do
            plan_year.start_on = start_on
            plan_year.end_on = end_on
          end

          it "should fail validation" do
            expect(plan_year.valid?).to be_falsey
            expect(plan_year.errors[:end_on].any?).to be_truthy
          end
        end

        context "and the plan year period is too long" do
          let(:invalid_length)  { Settings.aca.shop_market.benefit_period.length_maximum.year.years + 1.day }
          let(:start_on)  { TimeKeeper.date_of_record.end_of_month + 1 }
          let(:end_on)    { start_on + invalid_length }

          before do
            plan_year.start_on = start_on
            plan_year.end_on = end_on
          end

          it "should fail validation" do
            expect(plan_year.valid?).to be_falsey
            expect(plan_year.errors[:end_on].any?).to be_truthy
          end
        end

        context "and the open enrollment period is 5 days" do
          let(:minimum_open_enrollment_length) { Settings.aca.shop_market.open_enrollment.minimum_length.days }
          let(:open_enrollment_end_on) { Date.new(2015, 7, Settings.aca.shop_market.open_enrollment.monthly_end_on) }
          let(:open_enrollment_start_on) { open_enrollment_end_on - minimum_open_enrollment_length.days + 1.days }
          before do
            TimeKeeper.set_date_of_record_unprotected!(Date.new(2015, 7, 1))
            plan_year.open_enrollment_start_on = open_enrollment_start_on
            plan_year.open_enrollment_end_on = open_enrollment_end_on
            plan_year.valid?
          end

          it "should pass validation" do
            expect(plan_year.valid?).to be_truthy
          end

          it "should not have validation errors" do
            expect(plan_year.errors.messages).to eq({})
          end
        end

        context "and the plan year begins before open enrollment ends" do
          let(:valid_open_enrollment_length)  { Settings.aca.shop_market.open_enrollment.maximum_length.months.months }
          let(:valid_plan_year_length)  { Settings.aca.shop_market.benefit_period.length_maximum.year.years }
          let(:open_enrollment_start_on)  { TimeKeeper.date_of_record }
          let(:open_enrollment_end_on)    { open_enrollment_start_on + valid_open_enrollment_length }
          let(:start_on)  { open_enrollment_start_on - 1 }
          let(:end_on)    { start_on + valid_plan_year_length }

          before do
            plan_year.start_on = start_on
            plan_year.end_on = end_on
          end

          it "should fail validation" do
            expect(plan_year.valid?).to be_falsey
            expect(plan_year.errors[:start_on].any?).to be_truthy
          end
        end

        context "and the effective date is too far in the future" do
          let(:invalid_initial_application_date)  { TimeKeeper.date_of_record - Settings.aca.shop_market.initial_application.earliest_start_prior_to_effective_on.months.months + 1.month }
          let(:schedule)  { PlanYear.shop_enrollment_timetable(invalid_initial_application_date) }
          let(:start_on)  { schedule[:plan_year_start_on] }
          let(:end_on)    { schedule[:plan_year_end_on] }
          let(:open_enrollment_start_on) { schedule[:open_enrollment_earliest_start_on] }
          let(:open_enrollment_end_on)   { schedule[:open_enrollment_latest_end_on] }

          before do
            plan_year.start_on = start_on
            plan_year.end_on = end_on
            plan_year.open_enrollment_start_on = open_enrollment_start_on
            plan_year.open_enrollment_end_on = open_enrollment_end_on
          end

          it "should fail validation" do
            expect(plan_year.valid?).to be_falsey
            expect(plan_year.errors[:start_on].any?).to be_truthy
            expect(plan_year.errors[:start_on].first).to match(/may not start application before/)
          end
        end

        context "and the end of open enrollment is past deadline for effective date" do
          let(:schedule)  { PlanYear.shop_enrollment_timetable(TimeKeeper.date_of_record) }
          let(:start_on)  { schedule[:plan_year_start_on] }
          let(:end_on)    { schedule[:plan_year_end_on] }
          let(:open_enrollment_start_on) { schedule[:open_enrollment_latest_start_on] }
          let(:open_enrollment_end_on)   { schedule[:open_enrollment_latest_end_on] + 1 }

          before do
            plan_year.start_on = start_on
            plan_year.end_on = end_on
            plan_year.open_enrollment_start_on = open_enrollment_start_on
            plan_year.open_enrollment_end_on = open_enrollment_end_on
          end

          it "should fail validation on publish" do
            expect(plan_year.open_enrollment_date_errors.present?).to be_truthy
            expect(plan_year.open_enrollment_date_errors[:open_enrollment_period].first).to match(/Open enrollment must end on or before/i)
          end
        end

        context "when terminated plan year end_on is not end of month" do
          let(:plan_year)       { FactoryGirl.build(:plan_year, start_on:TimeKeeper.date_of_record.beginning_of_year, aasm_state: :terminated)}

          before do
            plan_year.end_on = TimeKeeper.date_of_record.end_of_year - 30.days
            plan_year.save!
          end

          it "should pass validation" do
            expect(plan_year.open_enrollment_date_errors.present?).to be_falsey
            expect(plan_year.errors.messages).to eq({})
            expect(plan_year.open_enrollment_date_errors).to eq({})
          end
        end
      end
    end
  end


  context ".publish" do

    let(:employer_profile) { FactoryGirl.create(:employer_profile) }
    let(:calender_year) { TimeKeeper.date_of_record.year }
    let(:plan_year_start_on) { Date.new(calender_year, 6, 1) }
    let(:open_enrollment_start_on) { Date.new(calender_year, 4, 1) }
    let(:open_enrollment_end_on) { Date.new(calender_year, 5, 13) }
    let(:plan_year) {
      py = FactoryGirl.create(:plan_year,
        start_on: plan_year_start_on,
        end_on: plan_year_start_on + 1.year - 1.day,
        open_enrollment_start_on: open_enrollment_start_on,
        open_enrollment_end_on: open_enrollment_end_on,
        employer_profile: employer_profile,
        aasm_state: 'renewing_draft'
        )

      blue = FactoryGirl.build(:benefit_group, title: "blue collar", plan_year: py)
      py.benefit_groups = [blue]
      py.save(:validate => false)
      py
    }


    before do
      TimeKeeper.set_date_of_record_unprotected!(Date.new(calender_year, 5, 1))
    end

    after :all do
      TimeKeeper.set_date_of_record_unprotected!(Date.today)
    end

    context "when open enrollment dates valid" do
      it 'should publish' do
        plan_year.publish!
        expect(plan_year.renewing_draft?).to be_falsey
      end
    end

    context "when open enrollment period too short" do
      before do
        plan_year.open_enrollment_start_on = plan_year.open_enrollment_end_on - 1.day
        plan_year.save(:validate => false)
      end

      it 'should error out' do
        plan_year.publish!
        expect(plan_year.renewing_draft?).to be_truthy
        expect(plan_year.open_enrollment_date_errors.values.flatten).to include("Open Enrollment period is shorter than minimum (#{Settings.aca.shop_market.renewal_application.open_enrollment.minimum_length.days} days)")
      end
    end


    context "when open enrollment period end date not satisfy business rule" do
      before do
        plan_year.open_enrollment_end_on = plan_year.open_enrollment_end_on + 3.day
        plan_year.save(:validate => false)
      end

      it 'should error out' do
        plan_year.publish!
        expect(plan_year.renewing_draft?).to be_truthy
        expect(plan_year.open_enrollment_date_errors.values.flatten).to include("Open Enrollment must end on or before the #{Settings.aca.shop_market.renewal_application.monthly_open_enrollment_end_on.ordinalize} day of the month prior to effective date")
      end
    end
  end

  context "an employer with renewal plan year application" do

    let(:benefit_group) { FactoryGirl.build(:benefit_group) }
    let(:plan_year_with_benefit_group) do
      py = PlanYear.new(**valid_params)
      py.employer_profile = employer_profile
      py.benefit_groups = [benefit_group]
      py.save
      py
    end

    before do
      plan_year_with_benefit_group.update_attributes(:aasm_state => 'renewing_draft')
    end

    after :all do
      TimeKeeper.set_date_of_record_unprotected!(Date.today)
    end

    it "plan year should be in renewing_draft state" do
      expect(plan_year_with_benefit_group.aasm_state).to eq "renewing_draft"
    end

    context "and plan year is published after the publish due date" do

      before do
        TimeKeeper.set_date_of_record_unprotected!(plan_year_with_benefit_group.due_date_for_publish + 1.day)
        plan_year_with_benefit_group.publish!
      end

      it "application should not be valid" do
        expect(plan_year_with_benefit_group.is_application_valid?).to be_falsey
      end

      it "and should provide relevant warnings" do
        expect(plan_year_with_benefit_group.application_errors[:publish].present?).to be_truthy
        expect(plan_year_with_benefit_group.application_errors[:publish]).to include(/Plan year starting on #{plan_year_with_benefit_group.start_on.strftime("%m-%d-%Y")} must be published by #{plan_year_with_benefit_group.due_date_for_publish.strftime("%m-%d-%Y")}/)
      end

      it "and plan year should be in publish pending state" do
        expect(plan_year_with_benefit_group.aasm_state).to eq "renewing_draft"
      end
    end

    context "and plan year is published before publish due date" do
      before do
        TimeKeeper.set_date_of_record_unprotected!(plan_year_with_benefit_group.due_date_for_publish.beginning_of_day)
        plan_year_with_benefit_group.publish!
      end

      it "application should be valid" do
        expect(plan_year_with_benefit_group.is_application_valid?).to be_truthy
      end

      it "and plan year should be in publish state" do
        expect(plan_year_with_benefit_group.aasm_state).to eq "renewing_enrolling"
      end
    end
  end

  context 'should return correct benefit group assignments for an employee' do
    let!(:employer_profile) { FactoryGirl.create(:employer_profile) }
    let(:plan_year_start_on) { TimeKeeper.date_of_record.end_of_month + 1.day }
    let(:plan_year_end_on) { (TimeKeeper.date_of_record + 1.year).end_of_month }
    let(:open_enrollment_start_on) { TimeKeeper.date_of_record.beginning_of_month }
    let(:open_enrollment_end_on) { open_enrollment_start_on + 12.days }
    let(:effective_date)         { plan_year_start_on }
    let!(:census_employee) { FactoryGirl.create(:census_employee,
                                                  employer_profile: employer_profile
                            ) }
    let!(:plan_year)                     { py = FactoryGirl.create(:plan_year,
                                                      start_on: plan_year_start_on,
                                                      end_on: plan_year_end_on,
                                                      open_enrollment_start_on: open_enrollment_start_on,
                                                      open_enrollment_end_on: open_enrollment_end_on,
                                                      employer_profile: employer_profile,
                                                      aasm_state: 'renewing_enrolled'
                                                    )

                                                    blue = FactoryGirl.build(:benefit_group, title: "blue collar", plan_year: py)
                                                    py.benefit_groups = [blue]
                                                    py.save(:validate => false)
                                                    py
                                                  }
    let!(:benefit_group_assignment) {
      BenefitGroupAssignment.create({
        census_employee: census_employee,
        benefit_group: plan_year.benefit_groups.first,
        start_on: plan_year_start_on
      })
    }

    let!(:renewal_benefit_group_assignment) {
      BenefitGroupAssignment.create({
        census_employee: census_employee,
        benefit_group: plan_year.benefit_groups.first,
        start_on: plan_year_start_on
      })
    }
    it 'should return renewing benefit group assignment' do
      expect(plan_year.enrolled_bga_for_ce(census_employee)).to eq renewal_benefit_group_assignment
    end

    it 'should retrun active benefit_group_assignment' do
      plan_year.update_attributes(:'aasm_state' => 'active')
      expect(plan_year.enrolled_bga_for_ce(census_employee)).to eq census_employee.benefit_group_assignments.first
    end
  end

  ## Initial application workflow process

  context "an employer prepares an initial plan year application" do
    let(:workflow_plan_year) { PlanYear.new(**valid_params) }

    it "plan year should be in draft state" do
      expect(workflow_plan_year.aasm_state).to eq "draft"
    end

    ## Application Errors
    context "and application is submitted with NO benefit groups defined" do
      before { workflow_plan_year.publish! }

      it "application should NOT be publishable" do
        expect(workflow_plan_year.is_application_unpublishable?).to be_truthy
      end

      it "and should provide relevent warning message" do
        expect(workflow_plan_year.application_errors[:benefit_groups].present?).to be_truthy
        expect(workflow_plan_year.application_errors[:benefit_groups]).to include(/You must create at least one benefit group/)
      end

      it "should be in draft status" do
        expect(workflow_plan_year.aasm_state).to eq "draft"
      end
    end

    context "and application is submitted with a benefit group defined" do
      let(:benefit_group) { FactoryGirl.build(:benefit_group) }
      let(:workflow_plan_year_with_benefit_group) do
        py = PlanYear.new(**valid_params)
        py.employer_profile = employer_profile
        py.benefit_groups = [benefit_group]
        py.save
        py
      end
      let(:plan_year1) { FactoryGirl.create(:renewing_plan_year)}

      context "and at least one employee is present on the roster sans assigned benefit group" do
        let!(:census_employee_no_benefit_group)   { FactoryGirl.create(:census_employee, employer_profile: employer_profile) }

        it "census employee has no benefit group assignment and employer profile is the same as plan year's" do
          expect(census_employee_no_benefit_group.benefit_group_assignments).to eq []
          expect(census_employee_no_benefit_group.employer_profile).to eq workflow_plan_year_with_benefit_group.employer_profile
        end

        it "application should NOT be publishable" do
          expect(workflow_plan_year_with_benefit_group.is_application_unpublishable?).to be_truthy
        end

        it "and should provide relevent warning message" do
          expect(workflow_plan_year_with_benefit_group.application_errors[:benefit_groups].present?).to be_truthy
          expect(workflow_plan_year_with_benefit_group.application_errors[:benefit_groups]).to include(/Every employee must be assigned to a benefit group/)
        end
      end

      context "and no employees on the roster" do
        before do
          workflow_plan_year_with_benefit_group.publish!
        end

        it "application should be publishable" do
          expect(workflow_plan_year_with_benefit_group.is_application_unpublishable?).to be_falsey
        end

        it "plan year should be in published state" do
          expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "published"
        end
      end

      context "and another published application for this employer exists for same plan year" do
        let(:published_plan_year)       { FactoryGirl.build(:plan_year, aasm_state: :published)}
        let(:published_benefit_group)   { FactoryGirl.build(:benefit_group) }

        before do
          published_plan_year.benefit_groups << published_benefit_group
          employer_profile.plan_years << published_plan_year
          published_plan_year.save
          employer_profile.save
        end

        it "second plan year application should NOT be publishable" do
          expect(workflow_plan_year_with_benefit_group.is_application_unpublishable?).to be_truthy
        end

        it "and should provide relevent error message" do
          expect(workflow_plan_year_with_benefit_group.application_errors[:publish].present?).to be_truthy
          expect(workflow_plan_year_with_benefit_group.application_errors[:publish]).to include(/You may only have one published plan year at a time/)
        end
      end

      context "and employer profile is in enrollment ineligible state" do
        before do
          employer_profile.plan_years = [workflow_plan_year_with_benefit_group]
          employer_profile.aasm_state = "ineligible"
        end

        it "application should NOT be publishable" do
          expect(workflow_plan_year_with_benefit_group.is_application_unpublishable?).to be_truthy
        end

        it "and should provide relevent warning message" do
          expect(workflow_plan_year_with_benefit_group.application_errors[:employer_profile].present?).to be_truthy
          expect(workflow_plan_year_with_benefit_group.application_errors[:employer_profile]).to include(/This employer is ineligible to enroll for coverage at this time/)
        end
      end

      ## Application Eligibility Warnings
      context "and employer's primary office isn't located in-state" do
        before do
          workflow_plan_year_with_benefit_group.employer_profile.organization.primary_office_location.address.state = "AK"
        end

        it "application should not be valid" do
          expect(workflow_plan_year_with_benefit_group.is_application_eligible?).to be_falsey
        end

        it "and should provide relevent warning message" do
          expect(workflow_plan_year_with_benefit_group.application_eligibility_warnings[:primary_office_location].present?).to be_truthy
          expect(workflow_plan_year_with_benefit_group.application_eligibility_warnings[:primary_office_location]).to match(/Has its principal business address in/)
        end
      end

      context "and the number of employees exceeds the maximum size count" do
        before do
          workflow_plan_year_with_benefit_group.fte_count = invalid_fte_count
          workflow_plan_year_with_benefit_group.publish
        end

        it "application should not be valid" do
          expect(workflow_plan_year_with_benefit_group.is_application_eligible?).to be_falsey
        end

        it "and should provide relevent warning message" do
          expect(workflow_plan_year_with_benefit_group.application_eligibility_warnings[:fte_count].present?).to be_truthy
          expect(workflow_plan_year_with_benefit_group.application_eligibility_warnings[:fte_count]).to match(/fewer full time equivalent employees/)
          expect(workflow_plan_year_with_benefit_group.application_eligibility_warnings[:valid_fte_count]).not_to match(/fewer full time equivalent employees/)
          expect(plan_year1.application_eligibility_warnings[:invalid_fte_count]).not_to match(/fewer full time equivalent employees/)
          expect(plan_year1.application_eligibility_warnings[:valid_fte_count]).not_to match(/fewer full time equivalent employees/)
        end

        it "and plan year should be in publish pending state" do
          expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "publish_pending"
        end
      end

      context "and plan year is published after the publish due date" do

        before do
          TimeKeeper.set_date_of_record_unprotected!(workflow_plan_year_with_benefit_group.due_date_for_publish + 1.day)
          workflow_plan_year_with_benefit_group.publish!
        end

        it "application should not be valid" do
          expect(workflow_plan_year_with_benefit_group.is_application_valid?).to be_falsey
        end

        it "and should provide relevant warnings" do
          expect(workflow_plan_year_with_benefit_group.application_errors[:publish].present?).to be_truthy
          expect(workflow_plan_year_with_benefit_group.application_errors[:publish]).to include(/Plan year starting on #{workflow_plan_year_with_benefit_group.start_on.strftime("%m-%d-%Y")} must be published by #{workflow_plan_year_with_benefit_group.due_date_for_publish.strftime("%m-%d-%Y")}/)
        end

        it "and plan year should be in publish pending state" do
          expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "draft"
        end
      end

      context "and plan year is published before publish due date" do
        before do
          TimeKeeper.set_date_of_record_unprotected!(workflow_plan_year_with_benefit_group.due_date_for_publish.beginning_of_day)
          workflow_plan_year_with_benefit_group.publish!
        end

        it "application should be valid" do
          expect(workflow_plan_year_with_benefit_group.is_application_valid?).to be_truthy
        end

        it "and plan year should be in publish state" do
          expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "enrolling"
        end
      end

      context "and the employer contribution amount is below minimum" do
        let(:invalid_relationship_benefit)  { RelationshipBenefit.new(
                                                relationship: :employee,
                                                offered: true,
                                                premium_pct: Settings.aca.shop_market.employer_contribution_percent_minimum - 1
                                              ) }

        let(:invalid_benefit_group)         { FactoryGirl.build(:benefit_group,
                                                relationship_benefits: [invalid_relationship_benefit]
                                              ) }

        let(:invalid_plan_year)             { PlanYear.new(**valid_params) }


        context "and the effective date isn't January 1" do
          let(:valid_plan_year_start_on)        { TimeKeeper.date_of_record.beginning_of_year + 1.month }

          before do
            TimeKeeper.set_date_of_record_unprotected!(valid_open_enrollment_start_on - 1)

            invalid_plan_year.benefit_groups << invalid_benefit_group
            invalid_plan_year.publish
          end

          it "application should not be valid" do
            expect(invalid_plan_year.is_application_eligible?).to be_falsey
          end

          it "and should provide relevent warning message" do
            expect(invalid_plan_year.application_eligibility_warnings[:minimum_employer_contribution].present?).to be_truthy
            expect(invalid_plan_year.application_eligibility_warnings[:minimum_employer_contribution]).to match(/Employer contribution percent/)
          end

          it "and plan year should be in publish pending state" do
            expect(invalid_plan_year.publish_pending?).to be_truthy
          end
        end

        context "and the effective date is January 1" do
          let(:valid_plan_year_start_on)        { TimeKeeper.date_of_record.beginning_of_year }

          before do
            TimeKeeper.set_date_of_record_unprotected!(valid_open_enrollment_start_on - 1)

            invalid_plan_year.benefit_groups << invalid_benefit_group
            invalid_plan_year.publish
          end

          it "application should be valid" do
            expect(invalid_plan_year.is_application_valid?).to be_truthy
          end

          it "and plan year should be in published state" do
            expect(invalid_plan_year.published?).to be_truthy
          end
        end
      end

      context "and applicant submits plan year application with eligibility errors" do
        before do
          workflow_plan_year_with_benefit_group.employer_profile.organization.primary_office_location.address.state = "AK"
          workflow_plan_year_with_benefit_group.publish!
        end

        it "application should not be valid" do
          expect(workflow_plan_year_with_benefit_group.is_application_eligible?).to be_falsey
        end

        it "should transition into publish pending status" do
          expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "publish_pending"
        end

        it "should record state transition and timestamp" do
          expect(workflow_plan_year_with_benefit_group.latest_workflow_state_transition.from_state).to eq "draft"
          expect(workflow_plan_year_with_benefit_group.latest_workflow_state_transition.to_state).to eq "publish_pending"
          expect(workflow_plan_year_with_benefit_group.latest_workflow_state_transition.transition_at.utc).to be_within(1.second).of(DateTime.now)
        end

        context "and the applicant chooses to cancel application submission" do
          before { workflow_plan_year_with_benefit_group.withdraw_pending! }

          it "should transition plan year application back to draft status" do
            expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "draft"
          end
        end

        context "and the applicant chooses to submit with application eligibility warnings" do
          let!(:submit_date) { TimeKeeper.date_of_record }

          before { workflow_plan_year_with_benefit_group.force_publish! }

          it "should transition plan year application into published_invalid status" do
            expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "published_invalid"
          end

          it "should transition applicant employer profile into enrollment ineligible status" do
            expect(employer_profile.aasm_state).to eq "ineligible"
          end

          context "and the employer doesn't request eligibility review" do
            context "and more than 90 days have elapsed since the ineligible application was submitted" do
              let!(:hbx_profile) { FactoryGirl.create(:hbx_profile, :open_enrollment_coverage_period) }
              before do
                TimeKeeper.set_date_of_record(submit_date + 90.days)
              end

              it "should transition employer profile to applicant status" do
                expect(EmployerProfile.find(employer_profile.id).aasm_state).to eq "applicant"
              end
            end
          end

          context "and the applicant requests eligibility review" do
            context "and 30 days or less have elapsed since application was submitted" do
              let!(:hbx_profile) { FactoryGirl.create(:hbx_profile, :open_enrollment_coverage_period) }
              before do
                TimeKeeper.set_date_of_record(submit_date + 10.days)
                workflow_plan_year_with_benefit_group.request_eligibility_review!
              end

              it "should transition into review status" do
                expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "eligibility_review"
              end

              context "and review overturns ineligible application determination" do
                let!(:hbx_profile) { FactoryGirl.create(:hbx_profile, :open_enrollment_coverage_period) }
                before { workflow_plan_year_with_benefit_group.grant_eligibility! }

                it "should transition application into published status" do
                  expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "published"
                end

                it "should transition employer profile into registered status" do
                  expect(employer_profile.aasm_state).to eq "registered"
                end
              end

              context "and review affirms ineligible application determination" do
                let!(:hbx_profile) { FactoryGirl.create(:hbx_profile, :open_enrollment_coverage_period) }
                before { workflow_plan_year_with_benefit_group.deny_eligibility! }

                it "should transition application back into published_invalid status" do
                  expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "published_invalid"
                end
              end
            end

            context "and more than 30 days have elapsed since application was submitted" do
              let!(:hbx_profile) { FactoryGirl.create(:hbx_profile, :open_enrollment_coverage_period) }
              before do
                TimeKeeper.set_date_of_record(submit_date + 31.days)
              end

              it "should not be able to request eligibility review" do
                expect {workflow_plan_year_with_benefit_group.request_eligibility_review!}.to raise_error(AASM::InvalidTransition)
              end

              context "and 90 days have elapsed since the ineligible application was submitted" do
                let!(:hbx_profile) { FactoryGirl.create(:hbx_profile, :open_enrollment_coverage_period) }
                before do
                  TimeKeeper.set_date_of_record(submit_date + Settings.aca.shop_market.initial_application.ineligible_period_after_application_denial.days)
                end

                it "should transition employer to applicant status" do
                  expect(EmployerProfile.find(employer_profile.id).aasm_state).to eq "applicant"
                end
              end
            end
          end
        end
      end

      ## Enrollment Errors
      context "and the employer submits a valid plan year application" do
        before do
          workflow_plan_year_with_benefit_group.publish!
        end

        it "application should be valid" do
          expect(workflow_plan_year_with_benefit_group.is_application_valid?).to be_truthy
        end

        it "plan year application should be in published state" do
          expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "published"
        end

        it "employer profile should be in registered state" do
          expect(workflow_plan_year_with_benefit_group.employer_profile.aasm_state).to eq "registered"
        end

        it "email invitations should go out to employees to sign up on the HBX"

        context "and employee signs into portal" do
          it "employees should be able to link to census employee roster"
          it "employees should be able to browse, but not purchase plans"

          context "and open enrollment begins" do
            let!(:hbx_profile) { FactoryGirl.create(:hbx_profile, :open_enrollment_coverage_period) }
            before do
              # $start_on = workflow_plan_year_with_benefit_group.open_enrollment_start_on
              TimeKeeper.set_date_of_record(workflow_plan_year_with_benefit_group.open_enrollment_start_on)
            end

            it "plan year application should be in enrolling state" do
              expect(PlanYear.find(workflow_plan_year_with_benefit_group.id).aasm_state).to eq "enrolling"
            end

            it "employees should be able to both browse and purchase plans"

            context "and six employees are eligible to enroll" do
              let(:employee_count)    { 6 }
              let(:census_employees)  { FactoryGirl.create_list(:census_employee,
                                          employee_count,
                                          employer_profile_id: workflow_plan_year_with_benefit_group.employer_profile.id
                                        )}
              let(:family)            { Family.create }

              def benefit_group_assignment
                BenefitGroupAssignment.new(
                  benefit_group: benefit_group,
                  start_on: workflow_plan_year_with_benefit_group.start_on,
                  hbx_enrollment: hbx_enrollment)
              end

              def hbx_enrollment
                HbxEnrollment.create(
                  household: family.households.first,
                  benefit_group_id: benefit_group.id,
                  coverage_kind: 'health',
                  kind: "unassisted_qhp")
              end

              context "and the business owner only has enrolled" do
                before do
                  census_employees[0].is_business_owner = true
                  census_employees[0].benefit_group_assignments = [benefit_group_assignment]
                  census_employees[0].active_benefit_group_assignment.select_coverage
                  census_employees[0].save

                  census_employees[1..employee_count - 1].each do |ee|
                    ee.benefit_group_assignments = [benefit_group_assignment]
                    ee.save
                  end
                end

                it "should include only eligible employees" do
                  workflow_plan_year_with_benefit_group.eligible_to_enroll.where(aasm_state:'eligible').update(aasm_state:'employment_terminated') # make 1 ineligible
                  expect(workflow_plan_year_with_benefit_group.eligible_to_enroll_count).to eq employee_count - 1
                  expect(workflow_plan_year_with_benefit_group.waived_count).to eq 0
                  expect(workflow_plan_year_with_benefit_group.covered_count).to eq 1
                  workflow_plan_year_with_benefit_group.eligible_to_enroll.where(aasm_state:'employment_terminated').update(aasm_state:'eligible') #set back to original state
                end

                it "should raise enrollment errors" do
                  if workflow_plan_year_with_benefit_group.start_on.yday == 1
                    expect((workflow_plan_year_with_benefit_group.enrollment_errors).size).to eq 1
                  else
                    expect((workflow_plan_year_with_benefit_group.enrollment_errors).size).to eq 2
                    expect(workflow_plan_year_with_benefit_group.enrollment_errors).to include(:enrollment_ratio)
                  end
                  expect(workflow_plan_year_with_benefit_group.enrollment_errors).to include(:non_business_owner_enrollment_count)
                end

                context "and three of the six employees have enrolled" do
                  let!(:hbx_profile) { FactoryGirl.create(:hbx_profile, :open_enrollment_coverage_period) }
                  before do
                    census_employees[0..2].each do |ee|
                      if ee.active_benefit_group_assignment.may_select_coverage?
                        ee.active_benefit_group_assignment.select_coverage
                        ee.save
                      end
#                      allow(HbxEnrollment).to receive(:find_shop_and_health_by_benefit_group_assignment).with(ee.active_benefit_group_assignment).and_return [hbx_enrollment]
                    end

                    bga_ids = census_employees.map do |ce|
                      ce.active_benefit_group_assignment.id
                    end
                    enrolled_bga_ids = census_employees[0..2].map do |ce|
                      ce.active_benefit_group_assignment.id
                    end
                    allow(HbxEnrollment).to receive(:enrolled_shop_health_benefit_group_ids).with(array_including(bga_ids)).and_return(enrolled_bga_ids)
                  end

                  it "should include all eligible employees" do
                    expect(workflow_plan_year_with_benefit_group.total_enrolled_count).to eq 3
                  end

                  it "should have the right enrollment ratio" do
                    expect(workflow_plan_year_with_benefit_group.enrollment_ratio).to eq 0.50
                  end

                  it "should have the right minimum enrolled count" do
                    expect(workflow_plan_year_with_benefit_group.minimum_enrolled_count).to eq 4.0
                  end

                  it "should have the right additional required participants count" do
                    expect(workflow_plan_year_with_benefit_group.additional_required_participants_count).to eq 1.0
                  end

                  context "greater than 200 employees " do
                    let(:employee_count)    { Settings.aca.shop_market.small_market_active_employee_limit + 1 }
                    before do
                      allow(workflow_plan_year_with_benefit_group).to receive_message_chain(:enrolled_by_bga, :count).and_return 25
                    end
                    context "active employees count greater than 200" do
                      it "should return 0" do
                        expect(workflow_plan_year_with_benefit_group.total_enrolled_count).to eq 0
                      end
                    end

                    context "active employees count less than 200" do
                      before do
                        workflow_plan_year_with_benefit_group.employer_profile.census_employees.limit(5).each do |census_employee|
                          census_employee.terminate_employee_role!
                        end
                      end
                      it "return enrolled count" do
                        expect(workflow_plan_year_with_benefit_group.total_enrolled_count).to eq 25
                      end
                    end
                  end

                  context "and the plan effective date is Jan 1" do
                    before do
                      workflow_plan_year_with_benefit_group.start_on = Date.new(2016, 1, 1)
                    end

                    it "should NOT raise enrollment errors" do
                      expect((workflow_plan_year_with_benefit_group.enrollment_errors).size).to eq 0
                    end
                  end

                  context "and the plan effective date is NOT Jan 1" do

                    it "should raise enrollment errors" do
                      if workflow_plan_year_with_benefit_group.start_on.yday != 1
                        expect((workflow_plan_year_with_benefit_group.enrollment_errors).size).to eq 1
                        expect(workflow_plan_year_with_benefit_group.enrollment_errors).to include(:enrollment_ratio)
                      end
                    end
                  end

                  context "and four of the six employees have enrolled or waived coverage" do
                    before do
                      ee = census_employees[employee_count - 1]
                      if ee.active_benefit_group_assignment.may_select_coverage?
                        ee.active_benefit_group_assignment.select_coverage
                        ee.save
                      end
                      bga_ids = census_employees.map do |ce|
                        ce.active_benefit_group_assignment.id
                      end
                      enrolled_bga_ids = census_employees[0..4].map do |ce|
                        ce.active_benefit_group_assignment.id
                      end
                      allow(HbxEnrollment).to receive(:enrolled_shop_health_benefit_group_ids).with(array_including(bga_ids)).and_return(enrolled_bga_ids)
                      # allow(HbxEnrollment).to receive(:find_shop_and_health_by_benefit_group_assignment).with(ee.active_benefit_group_assignment).and_return [hbx_enrollment]
                    end

                    it "should NOT raise enrollment errors" do
                      expect((workflow_plan_year_with_benefit_group.enrollment_errors).size).to eq 0
                    end

                    context "and open enrollment ends" do
                      before do
                        TimeKeeper.set_date_of_record(workflow_plan_year_with_benefit_group.open_enrollment_end_on + 1.day)
                      end

                      it "plan year application should be in enrolled state" do
                        expect(PlanYear.find(workflow_plan_year_with_benefit_group.id).aasm_state).to eq "enrolled"
                      end

                      it "plan year employer profile should be in registered state" do
                        expect(workflow_plan_year_with_benefit_group.employer_profile.aasm_state).to eq "registered"
                      end

                      context "and employee signs into portal" do
                        it "employees should be able to link to census employee roster"
                        it "employees should be able to browse and purchase plans"
                        it "employees' ability to purchase plans via OE should be disabled"
                        it "employees under active SEP should continue to be able to purchase plans"
                      end

                      context "and enrollment is valid" do
                        it "plan year application should be in enrolled state"
                        it "employer profile should be in registered state"
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      context "and employer submits a valid plan year application with open enrollment start before today" do
        before do
          TimeKeeper.set_date_of_record_unprotected!(Date.current.beginning_of_month - 1.month)
          workflow_plan_year_with_benefit_group.open_enrollment_start_on = TimeKeeper.date_of_record
          workflow_plan_year_with_benefit_group.open_enrollment_end_on = workflow_plan_year_with_benefit_group.open_enrollment_start_on + 5.days
          workflow_plan_year_with_benefit_group.start_on = TimeKeeper.date_of_record.beginning_of_month.next_month
          workflow_plan_year_with_benefit_group.end_on = workflow_plan_year_with_benefit_group.start_on + 1.year - 1.day
          workflow_plan_year_with_benefit_group.publish!
        end

        it "should transition directly to enrolling state" do
          expect(workflow_plan_year_with_benefit_group.aasm_state).to eq("enrolling")
        end
      end

      context "and employer submits a valid plan year application with today as start open enrollment" do
        before do
          TimeKeeper.set_date_of_record_unprotected!(Date.current.end_of_month + 1.day)
          workflow_plan_year_with_benefit_group.open_enrollment_start_on = TimeKeeper.date_of_record
          workflow_plan_year_with_benefit_group.open_enrollment_end_on = workflow_plan_year_with_benefit_group.open_enrollment_start_on + 5.days
          workflow_plan_year_with_benefit_group.start_on = workflow_plan_year_with_benefit_group.open_enrollment_start_on + 1.month
          workflow_plan_year_with_benefit_group.end_on = workflow_plan_year_with_benefit_group.start_on + 1.year - 1.day
          workflow_plan_year_with_benefit_group.publish!
          workflow_plan_year_with_benefit_group.advance_date!
        end

        it "should transition directly to enrolling state" do
          expect(workflow_plan_year_with_benefit_group.aasm_state).to eq("enrolling")
        end

        context "and today is the day following close of open enrollment" do
          let!(:hbx_profile) { FactoryGirl.create(:hbx_profile, :open_enrollment_coverage_period) }
          before do
            TimeKeeper.set_date_of_record(workflow_plan_year_with_benefit_group.open_enrollment_end_on + 1.day)
          end

          context "and enrollment non-owner participation minimum not met" do
            let(:invalid_non_owner_count) { Settings.aca.shop_market.non_owner_participation_count_minimum - 1 }
            let!(:owner_census_employee) { FactoryGirl.create(:census_employee, :owner, hired_on: (TimeKeeper.date_of_record - 2.years), employer_profile_id: employer_profile.id) }
            let!(:non_owner_census_families) { FactoryGirl.create_list(:census_employee, invalid_non_owner_count, hired_on: (TimeKeeper.date_of_record - 2.years), employer_profile_id: employer_profile.id) }

            before do
              owner_census_employee.add_benefit_group_assignment(benefit_group, workflow_plan_year_with_benefit_group.start_on)
              owner_census_employee.save!
              persisted_plan_year = PlanYear.find(workflow_plan_year_with_benefit_group.id)
              TimeKeeper.set_date_of_record(persisted_plan_year.open_enrollment_end_on + 1.day)
            end

            it "enrollment should be invalid" do
              expect(workflow_plan_year_with_benefit_group.is_enrollment_valid?).to be_falsey
              # expect(workflow_plan_year_with_benefit_group.enrollment_errors[:non_business_owner_enrollment_count].present?).to be_truthy
              expect(workflow_plan_year_with_benefit_group.enrollment_errors[:non_business_owner_enrollment_count]).to match(/non-owner employee must enroll/)
            end
          end
        end
      end

    end
  end

  context "application is submitted to be published" do
    let(:plan_year)                   { PlanYear.new(aasm_state: "draft", **valid_params) }
    let(:valid_fte_count)             { Settings.aca.shop_market.small_market_employee_count_maximum }
    let(:invalid_fte_count)           { Settings.aca.shop_market.small_market_employee_count_maximum + 1 }

    it "plan year should be in draft state" do
      expect(plan_year.draft?).to be_truthy
    end

    context "and the employer contribution amount is below minimum" do
      let(:benefit_group) { FactoryGirl.build(:benefit_group, :invalid_employee_relationship_benefit, plan_year: plan_year) }

      context "and the effective date isn't January 1" do

        let(:valid_plan_year_start_on)        { TimeKeeper.date_of_record.beginning_of_year + 1.month }

        before do
          TimeKeeper.set_date_of_record_unprotected!(valid_open_enrollment_start_on - 1)
          plan_year.benefit_groups << benefit_group
          plan_year.publish
        end

        it "application should not be valid" do
          expect(plan_year.is_application_eligible?).to be_falsey
        end

        it "and should provide relevent warning message" do
          expect(plan_year.application_eligibility_warnings[:minimum_employer_contribution].present?).to be_truthy
          expect(plan_year.application_eligibility_warnings[:minimum_employer_contribution]).to match(/Employer contribution percent/)
        end

        it "and plan year should be in publish pending state" do
          expect(plan_year.publish_pending?).to be_truthy
        end
      end

      context "and the effective date is January 1" do
        let(:valid_plan_year_start_on)        { TimeKeeper.date_of_record.beginning_of_year }

        before do
          TimeKeeper.set_date_of_record_unprotected!(valid_open_enrollment_start_on - 1)
          plan_year.benefit_groups << benefit_group
          plan_year.publish
        end

        it "application should be valid" do
          expect(plan_year.is_application_valid?).to be_truthy
        end

        it "and plan year should be in published state" do
          expect(plan_year.published?).to be_truthy
        end
      end
    end

    context "and one or more application elements are invalid" do
      let(:benefit_group) { FactoryGirl.build(:benefit_group, :invalid_employee_relationship_benefit, plan_year: plan_year) }

      let(:valid_plan_year_start_on)        { TimeKeeper.date_of_record.beginning_of_year + 1.month }

      before do
        TimeKeeper.set_date_of_record_unprotected!(valid_open_enrollment_start_on - 1)
        plan_year.benefit_groups << benefit_group
        plan_year.fte_count = invalid_fte_count
        plan_year.publish
      end

      it "and application should not be valid" do
        expect(plan_year.is_application_eligible?).to be_falsey
      end

      it "and plan year should be in publish pending state" do
        expect(plan_year.publish_pending?).to be_truthy
      end

      context "and application is withdrawn for correction" do
        before do
          plan_year.withdraw_pending
        end

        it "plan year should be in draft state" do
          expect(plan_year.draft?).to be_truthy
        end
      end

      context "and application is submitted with warnings" do
        before do
          plan_year.force_publish
        end

        it "plan year should be in publish invalid state" do
          expect(plan_year.published_invalid?).to be_truthy
        end

        it "employer_profile should be in ineligible state" do
          expect(plan_year.employer_profile.ineligible?).to be_truthy
        end

        # TODO: We need to determine the form this notification will take
        it "employer should be notified that applcation is ineligible"

        context "and 30 days or less has elapsed since applicaton was submitted" do
          context "and the employer appeals" do
            it "should transition to ineligible-appealing state"

            # TODO: We need to determine the form this notification will take
            it "should notify HBX representatives of appeal request"

              context "and HBX determines appeal has merit" do
                it "should transition employer status to registered"
              end

              context "and HBX determines appeal has no merit" do
                it "should transition employer status to ineligible"
              end

              context "and HBX determines application was submitted with errors" do
                it "should transition plan year application to draft"
                it "and should transition employer status to applicant"
              end
            end
          end

        context "and more than 30 days has elapsed since application was submitted" do
          it "should employer actually move the employer into an additional 60-day waiting period?"
        end
      end
    end

    context "and it has a terminated employee assigned to the benefit group" do
      let(:benefit_group) { FactoryGirl.build(:benefit_group) }

      before do
        plan_year.benefit_groups = [benefit_group]
        terminated_census_employee = FactoryGirl.create(
          :census_employee, employer_profile: plan_year.employer_profile,
          benefit_group_assignments: [FactoryGirl.build(:benefit_group_assignment, benefit_group: benefit_group)]
        )
        terminated_census_employee.terminate_employment!(TimeKeeper.date_of_record.yesterday)
      end

      # context "and all application elements are valid and it is published" do
      #   before do
      #     @starting_date_of_record = TimeKeeper.date_of_record
      #     TimeKeeper.set_date_of_record(plan_year.open_enrollment_start_on - 5.days)
      #     plan_year.publish
      #   end

      #   after do
      #     TimeKeeper.set_date_of_record(@starting_date_of_record)
      #   end

      #   it "plan year should publish" do
      #     expect(plan_year.published?).to be_truthy
      #   end

      #   it "and employer_profile should be in either registered or enrolling state" do
      #     expect(plan_year.employer_profile.registered? || plan_year.employer_profile.enrolling?).to be_truthy
      #   end

      #   context "and the plan year is changed" do
      #     before do
      #       plan_year.start_on = plan_year.start_on.next_month
      #       plan_year.end_on = plan_year.end_on.next_month
      #       plan_year.open_enrollment_start_on = plan_year.open_enrollment_start_on.next_month
      #       plan_year.open_enrollment_end_on = plan_year.open_enrollment_end_on.next_month
      #     end

      #     it "should not be valid"
      #   end
      # end
    end
  end

  context "and a published plan year application is reset to unpublished state", :dbclean => :after_all do
    let(:coverage_effective_date)   { TimeKeeper.date_of_record.end_of_month + 1.day }
    let(:renewal_health_plan)       { FactoryGirl.create(:plan, :with_premium_tables,
                                                          coverage_kind: "health",
                                                          active_year: coverage_effective_date.year.to_i + 1) }
    let(:current_health_plan)       { FactoryGirl.create(:plan, :with_premium_tables,
                                                          coverage_kind: "health",
                                                          active_year: (coverage_effective_date - 1.day).year.to_i,
                                                          renewal_plan_id: renewal_health_plan.id) }
    let(:benefit_group)             { FactoryGirl.build(:benefit_group,
                                                          reference_plan_id: current_health_plan.id,
                                                          elected_plans: [current_health_plan]) }
    let(:plan_year)                 { FactoryGirl.build(:plan_year,
                                                          start_on: coverage_effective_date,
                                                          end_on: coverage_effective_date + 1.year - 1.day,
                                                          benefit_groups: [benefit_group]) }
    let!(:employer_profile)         { FactoryGirl.create(:employer_profile, plan_years: [plan_year]) }


    before do
      TimeKeeper.set_date_of_record_unprotected!((coverage_effective_date - 1.day).beginning_of_month)
      plan_year.publish!
    end

    it "plan year should be in published state to support open enrollment" do
      expect(PlanYear.find(plan_year.id).aasm_state).to eq "enrolling"
    end

    it "employer should be in registered state" do
      expect(EmployerProfile.find(employer_profile.id).aasm_state).to eq "registered"
    end

    context "and the published plan_year application is reverted" do
      before do
        employer_profile.published_plan_year.revert_application!
      end

      it "should reset plan year to draft state" do
        expect(PlanYear.find(plan_year.id).aasm_state).to eq "draft"
      end

      it "should reset employer_profile to applicant state" do
        expect(EmployerProfile.find(employer_profile.id).aasm_state).to eq "applicant"
      end
    end

    context "and the employer_profile is in binder_paid state" do
      before do
        TimeKeeper.set_date_of_record_unprotected!(plan_year.open_enrollment_end_on + 1.day)
        employer_profile.published_plan_year.enroll
        employer_profile.binder_credited!
      end

      it "employer should be in binder_paid state" do
         expect(EmployerProfile.find(employer_profile.id).aasm_state).to eq "binder_paid"
      end

      context "and the plan_year application is reverted" do
        before do
          employer_profile.published_plan_year.revert_application!
        end

        it "should reset plan year to draft state" do
          expect(PlanYear.find(plan_year.id).aasm_state).to eq "draft"
        end

        it "should reset employer_profile to applicant state" do
          expect(EmployerProfile.find(employer_profile.id).aasm_state).to eq "applicant"
        end
      end
    end

    context "and employees have selected coverage" do
    end

    context "and sufficient time has passed, and the employer is renewing application" do
      let(:plan_year_renewal_factory) { Factories::PlanYearRenewalFactory.new }

      before do
        plan_year_renewal_factory.employer_profile = employer_profile
        TimeKeeper.set_date_of_record_unprotected!(coverage_effective_date + 1.year - 3.months)
        plan_year_renewal_factory.renew
      end

      it "should have a renewal plan year in draft state" do
        expect(employer_profile.renewing_plan_year.aasm_state).to eq "renewing_draft"
      end

      context "and the renewal plan year is published" do
        # let(:renewing_plan_year) { EmployerProfile.find(employer_profile.id).renewing_plan_year_drafts.first }

        before do
          employer_profile.renewing_plan_year.renew_publish!
        end

        it "should have a renewal plan year in published state" do
          expect(employer_profile.renewing_plan_year.aasm_state).to eq "renewing_published"
        end

        context "and the renewing plan year application is reverted" do
          before do
            employer_profile.renewing_plan_year.revert_renewal!
          end

          it "should reset plan year to draft state" do
            expect(employer_profile.renewing_plan_year.aasm_state).to eq "renewing_draft"
          end
        end
      end
    end
  end



  context "check_start_on" do
    it "should fail when effective date is not the first day of the month" do
      start_on = (TimeKeeper.date_of_record + 2.month).beginning_of_month + 10.days
      rsp = PlanYear.check_start_on(start_on)
      expect(rsp[:result]).to eq "failure"
      expect(rsp[:msg]).to eq "start on must be first day of the month"
    end

    it "should be valid when effective date is the first day of month" do
      start_on = (TimeKeeper.date_of_record + 2.month).beginning_of_month
      rsp = PlanYear.check_start_on(start_on)
      expect(rsp[:result]).to eq "ok"
      expect(rsp[:msg]).to eq ""
    end

    it "should fail when current date is later than open_enrollment_latest_start_on" do
      TimeKeeper.set_date_of_record_unprotected!(TimeKeeper.date_of_record.beginning_of_month + 14.days)
      start_on = (TimeKeeper.date_of_record + 1.month).beginning_of_month
      rsp = PlanYear.check_start_on(start_on)
      expect(rsp[:result]).to eq "failure"
      expect(rsp[:msg]).to start_with "must choose a start on date"
    end
  end

  context "calculate_open_enrollment_date when the earliest effective date is chosen" do
    let(:coverage_effective_date) { PlanYear.calculate_start_on_dates.first }
    let(:calculate_open_enrollment_date) { PlanYear.calculate_open_enrollment_date(coverage_effective_date) }

    context "on the first of the month" do
      let(:date_of_record_to_use) { Date.new(2015, 7, 1) }
      let(:expected_open_enrollment_start_on) { Date.new(2015, 7, 1) }
      let(:expected_open_enrollment_end_on) { Date.new(2015, 7, 10) }
      let(:expected_start_on) { Date.new(2015, 8, 1) }

      before do
        TimeKeeper.set_date_of_record_unprotected!(date_of_record_to_use)
      end

      it "should suggest correct open enrollment start" do
        expect(calculate_open_enrollment_date[:open_enrollment_start_on]).to eq expected_open_enrollment_start_on
      end

      it "should suggest correct open enrollment end" do
        expect(calculate_open_enrollment_date[:open_enrollment_end_on]).to eq expected_open_enrollment_end_on
      end

      it "should have the right start on" do
        expect(coverage_effective_date).to eq expected_start_on
      end
    end

    context "on the second of the month" do
      let(:date_of_record_to_use) { Date.new(2015, 7, 2) }
      let(:expected_open_enrollment_start_on) { Date.new(2015, 7, 2) }
      let(:expected_open_enrollment_end_on) { Date.new(2015, 7, 10) }
      let(:expected_start_on) { Date.new(2015, 8, 1) }
      before do
        TimeKeeper.set_date_of_record_unprotected!(date_of_record_to_use)
      end

      it "should suggest correct open enrollment start" do
        expect(calculate_open_enrollment_date[:open_enrollment_start_on]).to eq expected_open_enrollment_start_on
      end

      it "should suggest correct open enrollment end" do
        expect(calculate_open_enrollment_date[:open_enrollment_end_on]).to eq expected_open_enrollment_end_on
      end

      it "should have the right start on" do
        expect(coverage_effective_date).to eq expected_start_on
      end
    end

    context "on the third of the month" do
      let(:date_of_record_to_use) { Date.new(2015, 7, 3) }
      let(:expected_open_enrollment_start_on) { Date.new(2015, 7, 3) }
      let(:expected_open_enrollment_end_on) { Date.new(2015, 7, 10) }
      let(:expected_start_on) { Date.new(2015, 8, 1) }

      before do
        TimeKeeper.set_date_of_record_unprotected!(date_of_record_to_use)
      end

      it "should suggest correct open enrollment start" do
        expect(calculate_open_enrollment_date[:open_enrollment_start_on]).to eq expected_open_enrollment_start_on
      end

      it "should suggest correct open enrollment end" do
        expect(calculate_open_enrollment_date[:open_enrollment_end_on]).to eq expected_open_enrollment_end_on
      end

      it "should have the right start on" do
        expect(coverage_effective_date).to eq expected_start_on
      end
    end

    context "on the fourth of the month" do
      let(:date_of_record_to_use) { Date.new(2015, 7, 4) }
      let(:expected_open_enrollment_start_on) { Date.new(2015, 7, 4) }
      let(:expected_open_enrollment_end_on) { Date.new(2015, 7, 10) }
      let(:expected_start_on) { Date.new(2015, 8, 1) }

      before do
        TimeKeeper.set_date_of_record_unprotected!(date_of_record_to_use)
      end

      it "should suggest correct open enrollment start" do
        expect(calculate_open_enrollment_date[:open_enrollment_start_on]).to eq expected_open_enrollment_start_on
      end

      it "should suggest correct open enrollment end" do
        expect(calculate_open_enrollment_date[:open_enrollment_end_on]).to eq expected_open_enrollment_end_on
      end

      it "should have the right start on" do
        expect(coverage_effective_date).to eq expected_start_on
      end
    end

    context "on the fifth of the month" do
      let(:date_of_record_to_use) { Date.new(2015, 7, 5) }
      let(:expected_open_enrollment_start_on) { Date.new(2015, 7, 5) }
      let(:expected_open_enrollment_end_on) { Date.new(2015, 7, 10) }
      let(:expected_start_on) { Date.new(2015, 8, 1) }

      before do
        TimeKeeper.set_date_of_record_unprotected!(date_of_record_to_use)
      end

      it "should suggest correct open enrollment start" do
        expect(calculate_open_enrollment_date[:open_enrollment_start_on]).to eq expected_open_enrollment_start_on
      end

      it "should suggest correct open enrollment end" do
        expect(calculate_open_enrollment_date[:open_enrollment_end_on]).to eq expected_open_enrollment_end_on
      end

      it "should have the right start on" do
        expect(coverage_effective_date).to eq expected_start_on
      end
    end

    context "on the eleventh of the month" do
      let(:date_of_record_to_use) { Date.new(2015, 7, 11) }
      let(:expected_open_enrollment_start_on) { Date.new(2015, 7, 11) }
      let(:expected_open_enrollment_end_on) { Date.new(2015, 8, 10) }
      let(:expected_start_on) { Date.new(2015, 9, 1) }
      before do
        TimeKeeper.set_date_of_record_unprotected!(date_of_record_to_use)
      end

      it "should suggest correct open enrollment start" do
        expect(calculate_open_enrollment_date[:open_enrollment_start_on]).to eq expected_open_enrollment_start_on
      end

      it "should suggest correct open enrollment end" do
        expect(calculate_open_enrollment_date[:open_enrollment_end_on]).to eq expected_open_enrollment_end_on
      end

      it "should have the right start on" do
        expect(coverage_effective_date).to eq expected_start_on
      end
    end

    context "on the twelfth of the month" do
      let(:date_of_record_to_use) { Date.new(2015, 7, 12) }
      let(:expected_open_enrollment_start_on) { Date.new(2015, 7, 12) }
      let(:expected_open_enrollment_end_on) { Date.new(2015, 8, 10) }
      let(:expected_start_on) { Date.new(2015, 9, 1) }
      before do
        TimeKeeper.set_date_of_record_unprotected!(date_of_record_to_use)
      end

      it "should suggest correct open enrollment start" do
        expect(calculate_open_enrollment_date[:open_enrollment_start_on]).to eq expected_open_enrollment_start_on
      end

      it "should suggest correct open enrollment end" do
        expect(calculate_open_enrollment_date[:open_enrollment_end_on]).to eq expected_open_enrollment_end_on
      end

      it "should have the right start on" do
        expect(coverage_effective_date).to eq expected_start_on
      end
    end

  end

  context "map binder_payment_due_date" do
    it "in interval of map" do
      binder_payment_due_date = PlanYear.map_binder_payment_due_date_by_start_on(Date.new(2018,12,1))
      expect(binder_payment_due_date).to eq Date.new(2018,11,14)
      binder_payment_due_date_1 = PlanYear.map_binder_payment_due_date_by_start_on(Date.new(2019,9,1))
      expect(binder_payment_due_date_1).to eq Date.new(2019,8,13)
    end

    it "out of map" do
      binder_payment_due_date = PlanYear.map_binder_payment_due_date_by_start_on(Date.new(2021,9,1))

      expect(binder_payment_due_date).to eq PlanYear.shop_enrollment_timetable(Date.new(2021,9,1))[:binder_payment_due_date]
    end
  end

  context "calculate_start_on_options" do
    it "should return two options" do
      date1 = TimeKeeper.date_of_record.beginning_of_month.next_month.next_month
      date2 = date1.next_month
      dates = [date1, date2].map{|d| [d.strftime("%B %Y"), d.strftime("%Y-%m-%d")]}

      TimeKeeper.set_date_of_record_unprotected!(Date.new(TimeKeeper.date_of_record.year, TimeKeeper.date_of_record.month, 15))
      expect(PlanYear.calculate_start_on_options).to eq dates
    end

    it "should return three options" do
      date1 = TimeKeeper.date_of_record.beginning_of_month.next_month
      date2 = date1.next_month
      date3 = date2.next_month
      dates = [date1, date2, date3].map{|d| [d.strftime("%B %Y"), d.strftime("%Y-%m-%d")]}

      TimeKeeper.set_date_of_record_unprotected!(Date.new(TimeKeeper.date_of_record.year, TimeKeeper.date_of_record.month, 2))
      expect(PlanYear.calculate_start_on_options).to eq dates
    end
  end

  context "employee_participation_percent" do
    let(:employer_profile) {FactoryGirl.create(:employer_profile)}
    let(:plan_year) {FactoryGirl.create(:plan_year, employer_profile: employer_profile)}
    it "when fte_count equal 0" do
      allow(plan_year).to receive(:eligible_to_enroll_count).and_return(0)
      expect(plan_year.employee_participation_percent).to eq "-"
    end

    it "when fte_count > 0" do
      allow(plan_year).to receive(:eligible_to_enroll_count).and_return(10)
      allow(plan_year).to receive(:total_enrolled_count).and_return(4)
      expect(plan_year.employee_participation_percent).to eq "#{(4/10.0*100).round(2)}%"
    end
  end

  context "an employer with several families on the roster estimates the cost of a plan year" do
    def p(obj)
      obj.class.find(obj.id)
    end

    let!(:plan_year) { FactoryGirl.create(:plan_year, start_on: Date.new(2015,10,1) ) } #Make it pick the same reference plan
    let!(:blue_collar_benefit_group) { FactoryGirl.create(:benefit_group, :premiums_for_2015, title: "blue collar benefit group", plan_year: plan_year) }
    let!(:employer_profile) { plan_year.employer_profile }
    let!(:white_collar_benefit_group) { FactoryGirl.create(:benefit_group, :premiums_for_2015, plan_year: plan_year, title: "white collar benefit group") }
    let!(:blue_collar_large_family_employee) { FactoryGirl.create(:census_employee, employer_profile: employer_profile) }
    let!(:blue_collar_large_family_dependents) { FactoryGirl.create_list(:census_dependent, 5, census_employee: blue_collar_large_family_employee) }
    let!(:blue_collar_small_family_employee) { FactoryGirl.create(:census_employee, employer_profile: employer_profile) }
    let!(:blue_collar_small_family_dependents) { FactoryGirl.create_list(:census_dependent, 2, census_employee: blue_collar_small_family_employee) }
    let!(:blue_collar_no_family_employee) { FactoryGirl.create(:census_employee, employer_profile: employer_profile) }
    let!(:blue_collar_employees) { [blue_collar_large_family_employee, blue_collar_small_family_employee, blue_collar_no_family_employee]}
    let!(:white_collar_large_family_employee) { FactoryGirl.create(:census_employee, employer_profile: employer_profile) }
    let!(:white_collar_large_family_dependents) { FactoryGirl.create_list(:census_dependent, 5, census_employee: white_collar_large_family_employee) }
    let!(:white_collar_small_family_employee) { FactoryGirl.create(:census_employee, employer_profile: employer_profile) }
    let!(:white_collar_small_family_dependents) { FactoryGirl.create_list(:census_dependent, 2, census_employee: white_collar_small_family_employee) }
    let!(:white_collar_no_family_employee) { FactoryGirl.create(:census_employee, employer_profile: employer_profile) }
    let!(:white_collar_employees) { [white_collar_large_family_employee, white_collar_small_family_employee, white_collar_no_family_employee]}
    #Whoever did these by hand is hardcore.
    let(:estimated_monthly_max_cost) { 2154.18 }
    let(:estimated_min_employee_cost) { 100.10 }
    let(:estimated_max_employee_cost) { 1121.10 }

    before do
      blue_collar_employees.each do |ce|
        ce.benefit_group_assignments.each{|bg| bg.delete }
        FactoryGirl.create(:benefit_group_assignment, census_employee: ce, benefit_group: blue_collar_benefit_group)
      end
      white_collar_employees.each do |ce|
        ce.benefit_group_assignments.each{|bg| bg.delete }
        FactoryGirl.create(:benefit_group_assignment, census_employee: ce, benefit_group: white_collar_benefit_group)
      end
    end

    it "should have an estimated monthly max cost" do
      Caches::PlanDetails.load_record_cache!
      expect(p(blue_collar_benefit_group).monthly_employer_contribution_amount).to be_within(0.01).of(estimated_monthly_max_cost)
    end

    it "should have an estimated min employee cost" do
      Caches::PlanDetails.load_record_cache!
      expect(p(blue_collar_benefit_group).monthly_min_employee_cost).to be_within(0.01).of(estimated_min_employee_cost)
    end

    it "should have an estimated max employee cost" do
      Caches::PlanDetails.load_record_cache!
      expect(p(blue_collar_benefit_group).monthly_max_employee_cost).to be_within(0.01).of(estimated_max_employee_cost)
    end
  end


  context 'published_plan_years_within_date_range scope' do

    let!(:employer_profile)               { FactoryGirl.create(:employer_profile) }
    let(:valid_fte_count)                 { 5 }
    let(:max_fte_count)                   { HbxProfile::ShopSmallMarketFteCountMaximum }
    let(:invalid_fte_count)               { HbxProfile::ShopSmallMarketFteCountMaximum + 1 }

    before do
       (1..3).each do |months_from_now|
          valid_plan_year_start_on = TimeKeeper.date_of_record.end_of_month + 1.day + months_from_now.months
          valid_open_enrollment_start_on = valid_plan_year_start_on - 1.month

          plan_year = PlanYear.new({
            employer_profile: employer_profile,
            start_on: valid_plan_year_start_on,
            end_on: valid_plan_year_start_on + 1.year - 1.day,
            open_enrollment_start_on: valid_open_enrollment_start_on,
            open_enrollment_end_on: valid_open_enrollment_start_on + 9.days,
            fte_count: valid_fte_count,
            imported_plan_year: true
            })

          plan_year.benefit_groups = [FactoryGirl.build(:benefit_group)]
          plan_year.save!
        end
    end

    context 'when plan year start date overlaps with published plan year' do
      it 'should return plan year' do
        employer_profile.plan_years[1].publish!
        current_plan_year = employer_profile.plan_years.first
        expect(employer_profile.plan_years[0].overlapping_published_plan_years.any?).to be_truthy
        expect(employer_profile.plan_years[2].overlapping_published_plan_years.any?).to be_truthy
      end
    end


    context 'when plan year start date overlaps with published plan year' do

      before do

        old_plan_year_start_on = TimeKeeper.date_of_record.end_of_month + 1.day - 1.year

        old_plan_year = PlanYear.new({
            employer_profile: employer_profile,
            start_on: old_plan_year_start_on,
            end_on: old_plan_year_start_on + 1.year - 1.day,
            open_enrollment_start_on: old_plan_year_start_on - 1.month,
            open_enrollment_end_on: old_plan_year_start_on - 1.month + 9.days,
            fte_count: valid_fte_count,
            imported_plan_year: true
            })

        old_plan_year.benefit_groups = [FactoryGirl.build(:benefit_group)]
        old_plan_year.save!
        old_plan_year.publish!
      end

      it 'should return plan year' do
        expect(employer_profile.plan_years[0].overlapping_published_plan_years.any?).to be_falsey
      end
    end
  end

  context '.hbx_enrollments_by_month' do
    let!(:employer_profile)          { FactoryGirl.create(:employer_profile) }
    let!(:census_employee) { FactoryGirl.create(:census_employee, first_name: 'John', last_name: 'Smith', dob: '1966-10-10'.to_date, ssn: '123456789', hired_on: TimeKeeper.date_of_record) }
    let!(:person) { FactoryGirl.create(:person, first_name: 'John', last_name: 'Smith', dob: '1966-10-10'.to_date, ssn: '123456789') }

    let!(:employee_role) {
      person.employee_roles.create(
        employer_profile: employer_profile,
        hired_on: census_employee.hired_on,
        census_employee_id: census_employee.id
      )
    }

    let!(:shop_family)       { FactoryGirl.create(:family, :with_primary_family_member, :person => person) }

    let(:plan_year_start_on) { TimeKeeper.date_of_record.end_of_month + 1.day }
    let(:plan_year_end_on)   { (TimeKeeper.date_of_record + 1.year).end_of_month }
    let(:open_enrollment_start_on) { TimeKeeper.date_of_record.beginning_of_month }
    let(:open_enrollment_end_on) { open_enrollment_start_on + 12.days }
    let(:effective_date)         { plan_year_start_on }

    let!(:renewing_plan_year)                     { py = FactoryGirl.create(:plan_year,
                                                      start_on: plan_year_start_on,
                                                      end_on: plan_year_end_on,
                                                      open_enrollment_start_on: open_enrollment_start_on,
                                                      open_enrollment_end_on: open_enrollment_end_on,
                                                      employer_profile: employer_profile,
                                                      aasm_state: 'renewing_enrolled'
                                                    )

                                                    blue = FactoryGirl.build(:benefit_group, title: "blue collar", plan_year: py)
                                                    py.benefit_groups = [blue]
                                                    py.save(:validate => false)
                                                    py
                                                  }

    let!(:plan_year)                              { py = FactoryGirl.create(:plan_year,
                                                      start_on: plan_year_start_on - 1.year,
                                                      end_on: plan_year_end_on - 1.year,
                                                      open_enrollment_start_on: open_enrollment_start_on - 1.year,
                                                      open_enrollment_end_on: open_enrollment_end_on - 1.year - 3.days,
                                                      employer_profile: employer_profile,
                                                      aasm_state: 'active'
                                                    )

                                                    blue = FactoryGirl.build(:benefit_group, title: "blue collar", plan_year: py)
                                                    py.benefit_groups = [blue]
                                                    py.save(:validate => false)
                                                    py
                                                  }

    let!(:benefit_group_assignment) {
      BenefitGroupAssignment.create({
        census_employee: census_employee,
        benefit_group: renewing_plan_year.benefit_groups.first,
        start_on: plan_year_start_on - 1.year
      })
    }

    let!(:renewal_benefit_group_assignment) {
      BenefitGroupAssignment.create({
        census_employee: census_employee,
        benefit_group: plan_year.benefit_groups.first,
        start_on: plan_year_start_on
      })
    }

    let!(:health_enrollment)   { FactoryGirl.create(:hbx_enrollment,
      household: shop_family.latest_household,
      coverage_kind: "health",
      effective_on: effective_date - 1.year,
      enrollment_kind: "open_enrollment",
      kind: "employer_sponsored",
      submitted_at: effective_date - 11.months,
      benefit_group_id: plan_year.benefit_groups.first.id,
      employee_role_id: employee_role.id,
      benefit_group_assignment_id: benefit_group_assignment.id
      )
    }

    let!(:dental_enrollment)   { FactoryGirl.create(:hbx_enrollment,
      household: shop_family.latest_household,
      coverage_kind: "dental",
      effective_on: effective_date - 1.year,
      enrollment_kind: "open_enrollment",
      kind: "employer_sponsored",
      submitted_at: effective_date - 11.months,
      benefit_group_id: plan_year.benefit_groups.first.id,
      employee_role_id: employee_role.id,
      benefit_group_assignment_id: benefit_group_assignment.id
      )
    }

    let!(:auto_renewing_enrollment)   { FactoryGirl.create(:hbx_enrollment,
      household: shop_family.latest_household,
      coverage_kind: "health",
      effective_on: effective_date,
      enrollment_kind: "open_enrollment",
      kind: "employer_sponsored",
      submitted_at: effective_date,
      benefit_group_id: renewing_plan_year.benefit_groups.first.id,
      employee_role_id: employee_role.id,
      benefit_group_assignment_id: renewal_benefit_group_assignment.id,
      aasm_state: 'auto_renewing'
      )
    }

    context 'when renewing plan year begin date passed' do

      context 'when only auto renewal present' do
        it 'should return auto renewal' do
          expect(renewing_plan_year.hbx_enrollments_by_month(effective_date)).to eq [auto_renewing_enrollment]
        end
      end

      context "when auto renewal is waived" do
        before do
          auto_renewing_enrollment.update_attributes(:'aasm_state' => 'renewing_waived')
        end

        it 'should not return waived enrollments' do
          expect(renewing_plan_year.hbx_enrollments_by_month(effective_date)).to eq []
        end
      end

      context 'when employee manually purchased coverage' do

        let!(:employee_purchased_coverage)   { FactoryGirl.create(:hbx_enrollment,
          household: shop_family.latest_household,
          coverage_kind: "health",
          effective_on: effective_date,
          enrollment_kind: "open_enrollment",
          kind: "employer_sponsored",
          submitted_at: effective_date,
          benefit_group_id: renewing_plan_year.benefit_groups.first.id,
          employee_role_id: employee_role.id,
          benefit_group_assignment_id: renewal_benefit_group_assignment.id,
          aasm_state: 'coverage_selected'
          )
        }

        it 'should return employee coverage selection' do
          expect(renewing_plan_year.hbx_enrollments_by_month(effective_date)).to eq [employee_purchased_coverage]
        end
      end

      context 'when current date passed' do
        context 'when both health and dental are active' do
          it 'should return auto renewal' do
            expect(plan_year.hbx_enrollments_by_month(effective_date - 1.month)).to eq [health_enrollment, dental_enrollment]
          end
        end

        context 'when health coverage terminated' do

          before do
            health_enrollment.update_attributes(:aasm_state => 'coverage_terminated', :terminated_on => effective_date - 45.days)
          end

          it 'should return only dental coverage when health coverage expired' do
            expect(plan_year.hbx_enrollments_by_month(effective_date - 1.month)).to eq [dental_enrollment]
          end

          it 'should return both health and dental when both active for at least 1 day of month' do
            expect(plan_year.hbx_enrollments_by_month(effective_date - 2.months)).to eq [health_enrollment, dental_enrollment]
            expect(plan_year.hbx_enrollments_by_month(effective_date - 3.months)).to eq [health_enrollment, dental_enrollment]
          end
        end
      end
    end
  end


  context '.adjust_open_enrollment_date' do
    let(:employer_profile)          { FactoryGirl.create(:employer_profile) }
    let(:calender_year) { TimeKeeper.date_of_record.year }
    let(:plan_year_start_on) { Date.new(calender_year, 4, 1) }
    let(:plan_year_end_on) { Date.new(calender_year + 1, 3, 31) }
    let(:open_enrollment_start_on) { Date.new(calender_year, 2, 3) }
    let(:open_enrollment_end_on) { Date.new(calender_year, 3, 13) }
    let!(:plan_year)                               { py = FactoryGirl.create(:plan_year,
                                                      start_on: plan_year_start_on,
                                                      end_on: plan_year_end_on,
                                                      open_enrollment_start_on: open_enrollment_start_on,
                                                      open_enrollment_end_on: open_enrollment_end_on,
                                                      employer_profile: employer_profile,
                                                      aasm_state: 'renewing_draft'
                                                    )

                                                    blue = FactoryGirl.build(:benefit_group, title: "blue collar", plan_year: py)
                                                    py.benefit_groups = [blue]
                                                    py.save(:validate => false)
                                                    py
                                                  }


    before do
      TimeKeeper.set_date_of_record_unprotected!(open_enrollment_start_on + 10.days)
    end

    after do
      TimeKeeper.set_date_of_record_unprotected!(Date.today)
    end

    it 'should reset open enrollment date when published plan year' do
      plan_year.publish!
      expect(plan_year.aasm_state).to eq 'renewing_enrolling'
      expect(plan_year.open_enrollment_start_on).to eq (open_enrollment_start_on + 10.days)
    end
  end

  describe 'sends employee invitation email', focus: true do
    include_context 'MailSpecHelper'

    context 'when .is_renewal?' do
      let(:employer_profile) { FactoryGirl.create(:employer_profile) }
      let(:calender_year) { TimeKeeper.date_of_record.year }
      let(:plan_year_start_on) { Date.new(calender_year, 4, 1) }
      let(:plan_year_end_on) { Date.new(calender_year + 1, 3, 31) }
      let(:open_enrollment_start_on) { Date.new(calender_year, 2, 1) }
      let(:open_enrollment_end_on) { Date.new(calender_year, 3, 13) }
      let!(:plan_year) { FactoryGirl.create(:plan_year,
                                              start_on: plan_year_start_on,
                                              end_on: plan_year_end_on,
                                              open_enrollment_start_on: open_enrollment_start_on,
                                              open_enrollment_end_on: open_enrollment_end_on,
                                              employer_profile: employer_profile,
                                              aasm_state: 'renewing_draft'
                                            )}
      let!(:benefit_group)            { FactoryGirl.build(:benefit_group,
                                                            title: 'blue collar',
                                                            plan_year: plan_year) }

      let!(:benefit_group_assignment) { FactoryGirl.build(:benefit_group_assignment,
                                                            benefit_group: benefit_group) }

      let!(:census_employee) { FactoryGirl.create(:census_employee,
                                                    employer_profile: employer_profile,
                                                    benefit_group_assignments: [benefit_group_assignment]
                              ) }
      before do
        refresh_mailbox
        TimeKeeper.set_date_of_record_unprotected!(open_enrollment_start_on + 10.days)
        plan_year.publish!
      end

      after(:all) do
        refresh_mailbox
        TimeKeeper.set_date_of_record_unprotected!(Date.today)
      end

      it 'the plan should be in renewing enrolling' do
        expect(plan_year.is_renewing?).to be_truthy
        expect(plan_year.aasm_state).to eq('renewing_enrolling')
      end

      it 'should fire an event' do
        expect(plan_year).to receive(:notify).with("acapi.info.events.plan_year.employee_renewal_invitations_requested", {:plan_year_id=> plan_year.id.to_s})
        plan_year.send(:send_employee_invites)
      end

      it 'should send invitations to renewal census employees' do
        expect(Invitation).to receive(:invite_renewal_employee!).with(census_employee)
        plan_year.send_employee_renewal_invites
      end


      it 'should send invitations to benefit group census employees'
      # Find a way to test this that relies on the event being fired, as well as write companion specs
      # to determine if the content is correct.  Right now this doesn't really check much
      # other than that the mail bin isn't empty.

      context "enrolling" do
        before do
          refresh_mailbox
          plan_year.open_enrollment_end_on = Date.new(calender_year, 3, 10)
          plan_year.aasm_state = "draft"
          plan_year.publish!
          TimeKeeper.set_date_of_record_unprotected!(open_enrollment_start_on + 5.days)
        end

        it 'the plan should be in enrolling' do
          expect(plan_year.enrolling?).to be_truthy
          expect(plan_year.aasm_state).to eq('enrolling')
        end

        it 'should fire an event' do
          expect(plan_year).to receive(:notify).with("acapi.info.events.plan_year.employee_initial_enrollment_invitations_requested", {:plan_year_id=> plan_year.id.to_s})
          plan_year.send(:send_employee_invites)
        end

        it 'should send invitations to initial census employees' do
          expect(Invitation).to receive(:invite_initial_employee!).with(census_employee)
          plan_year.send_employee_initial_enrollment_invites
        end

        it 'should send invitations to benefit group census employees'
        # Find a way to test this that relies on the event being fired, as well as write companion specs
        # to determine if the content is correct.  Right now this doesn't really check much
        # other than that the mail bin isn't empty.
      end
    end
  end

  describe PlanYear, "Transitions from active or expired to expired migrations" do
    let(:benefit_group) { FactoryGirl.build(:benefit_group) }
    let!(:employer_profile) { FactoryGirl.build(:employer_profile, profile_source: "conversion", registered_on: TimeKeeper.date_of_record)}
    let(:valid_plan_year_start_on)        { TimeKeeper.date_of_record - 1.year + 1.month}
    let(:valid_plan_year_end_on)          { valid_plan_year_start_on + 1.year - 1.day }
    let(:valid_open_enrollment_start_on)  { valid_plan_year_start_on.prev_month }
    let(:valid_open_enrollment_end_on)    { valid_open_enrollment_start_on + 9.days }

    let(:valid_params) do
      {
        employer_profile: employer_profile,
        start_on: valid_plan_year_start_on,
        end_on: valid_plan_year_end_on,
        open_enrollment_start_on: valid_open_enrollment_start_on,
        open_enrollment_end_on: valid_open_enrollment_end_on,
        fte_count: valid_fte_count
      }
    end
    let(:workflow_plan_year_with_benefit_group) do
      py = PlanYear.new(**valid_params)
      py.aasm_state = "active"
      py.is_conversion = true
      py.employer_profile = employer_profile
      py.benefit_groups = [benefit_group]
      py.save
      py
    end

    context "this should trigger a state transition" do
      it "should change its aasm state" do
        workflow_plan_year_with_benefit_group.update(is_conversion: true)
        expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "active"
        workflow_plan_year_with_benefit_group.conversion_expire!
        expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "conversion_expired"
      end

      it "should not change its aasm state" do
        workflow_plan_year_with_benefit_group.update(is_conversion: true)
        workflow_plan_year_with_benefit_group.aasm_state = "enrolled"
        workflow_plan_year_with_benefit_group.save
        expect { workflow_plan_year_with_benefit_group.conversion_expire!}.to raise_error(AASM::InvalidTransition)
        expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "enrolled"
      end

      it "should not trigger a state transitioin" do
        workflow_plan_year_with_benefit_group.employer_profile.registered_on = TimeKeeper.date_of_record + 45.days
        workflow_plan_year_with_benefit_group.is_conversion = false
        workflow_plan_year_with_benefit_group.save
        expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "active"
        expect { workflow_plan_year_with_benefit_group.conversion_expire!}.to raise_error(AASM::InvalidTransition)
        expect(workflow_plan_year_with_benefit_group.aasm_state).to eq "active"
      end
    end
  end
end

describe PlanYear, "which has the concept of export eligibility" do
  ALL_STATES = PlanYear.aasm.states.map(&:name).map(&:to_s)
  INVALID_EXPORT_STATES = PlanYear::INELIGIBLE_FOR_EXPORT_STATES
  EXPORTABLE_STATES = ALL_STATES - INVALID_EXPORT_STATES

  subject { PlanYear.new(:aasm_state => export_state) }

  INVALID_EXPORT_STATES.each do |astate|
    describe "in #{astate} state" do
      let(:export_state) { astate}
      it "is not eligible for export" do
        expect(subject.eligible_for_export?).not_to eq true
      end
    end
  end

  describe PlanYear, "state machine transitions -- unhappy path" do

    context "an initial employer publishes a valid application and begins open enrollment" do

      let(:benefit_group) { FactoryGirl.build(:benefit_group) }
      let!(:employer_profile) { FactoryGirl.build(:employer_profile)}

      let(:valid_plan_year_start_on)        { Date.new(2016, 11, 1) }
      let(:valid_plan_year_end_on)          { valid_plan_year_start_on + 1.year - 1.day }
      let(:valid_open_enrollment_start_on)  { valid_plan_year_start_on.prev_month }
      let(:valid_open_enrollment_end_on)    { valid_open_enrollment_start_on + 9.days }

      let!(:plan_year) do
        py = PlanYear.new({
          employer_profile: employer_profile,
          start_on: valid_plan_year_start_on,
          end_on: valid_plan_year_end_on,
          open_enrollment_start_on: valid_open_enrollment_start_on,
          open_enrollment_end_on: valid_open_enrollment_end_on
          })

        py.aasm_state = "draft"
        py.benefit_groups = [benefit_group]
        py.save
        py
      end

      let!(:owner) { FactoryGirl.create(:census_employee, :owner, hired_on: (TimeKeeper.date_of_record - 2.years), employer_profile_id: employer_profile.id) }
      let!(:non_owner) { FactoryGirl.create_list(:census_employee, 2, hired_on: (TimeKeeper.date_of_record - 2.years), employer_profile_id: employer_profile.id) }

      before do
        TimeKeeper.set_date_of_record_unprotected!(valid_open_enrollment_start_on)
        plan_year.publish!
      end

      it "plan year should be in enrolling state" do
        expect(plan_year.enrolling?).to be_truthy
        expect(plan_year.employer_profile.registered?).to be_truthy
      end

      context "and open enrollment ends, but eligibility requirements are not met" do

        before do
          TimeKeeper.set_date_of_record_unprotected!(valid_open_enrollment_end_on + 1.day)
          plan_year.advance_date!
        end

        it "should fail to meet the employee_participation_ratio_minimum" do
          expect(plan_year.enrollment_errors[:enrollment_ratio].present?).to be_truthy
        end

        it "should transition application to ineligible state" do
          expect(plan_year.application_ineligible?).to be_truthy
        end

        it "should transition employer to applicant state" do
          expect(employer_profile.applicant?).to be_truthy
        end
      end
    end
  end

end

describe PlanYear, "filter_active_enrollments_by_date" do
  let(:plan_year) { FactoryGirl.create(:plan_year)}
  let!(:benefit_group) { FactoryGirl.build(:benefit_group, plan_year: plan_year) }
  let(:benefit_group_assignment) { double("benefit_group_assignment", id: "bga") }
  let(:family) { FactoryGirl.create(:family, :with_primary_family_member)}
  let(:health_enrollment) { FactoryGirl.create(:hbx_enrollment, coverage_kind: 'health', household: family.active_household)}
  let(:dental_enrollment) { FactoryGirl.create(:hbx_enrollment, coverage_kind: 'dental', household: family.active_household)}

  before do
    health_enrollment.update_attributes(benefit_group_assignment_id: benefit_group_assignment.id, effective_on: plan_year.start_on, benefit_group_id: benefit_group.id)
    dental_enrollment.update_attributes(benefit_group_assignment_id: benefit_group_assignment.id, effective_on: plan_year.start_on, benefit_group_id: benefit_group.id)
  end

  it 'should return an array of openstruct' do
    result = plan_year.filter_active_enrollments_by_date(plan_year.start_on)
    expect(result.class).to eq Array
    expect(result.first.class).to eq OpenStruct
  end

  it 'should return both health & dental enrollment ids' do
    result = plan_year.filter_active_enrollments_by_date(plan_year.start_on)
    expect(result.map(&:hbx_enrollment_id)).to eq [dental_enrollment.id, health_enrollment.id]
  end

  it 'should return both health & dental plan ids' do
    result = plan_year.filter_active_enrollments_by_date(plan_year.start_on)
    expect(result.map(&:plan_id)).to eq [dental_enrollment.plan.id, health_enrollment.plan.id]
  end

  context "termination date of enrollment is prior to the billing date" do

    before do
      health_enrollment.update_attributes(terminated_on: plan_year.end_on - 3.months)
    end

    it 'should not return health enrollment' do
      result = plan_year.filter_active_enrollments_by_date(plan_year.end_on - 1.months)
      expect(result.map(&:plan_id).include?(health_enrollment.plan.id)).to eq false
    end

    it 'should return only dental_enrollment' do
      result = plan_year.filter_active_enrollments_by_date(plan_year.end_on - 1.months)
      expect(result.map(&:plan_id)).to eq [dental_enrollment.plan.id]
    end
  end
end

#11021
describe PlanYear, "plan year schedule changes" do

  context "initial employer plan year" do

    let(:benefit_group) { FactoryGirl.build(:benefit_group) }
    let!(:employer_profile) { FactoryGirl.build(:employer_profile)}

    let(:valid_plan_year_start_on)        { Date.new(2016, 11, 1) }
    let(:valid_plan_year_end_on)          { valid_plan_year_start_on + 1.year - 1.day }
    let(:valid_open_enrollment_start_on)  { valid_plan_year_start_on.prev_month }
    let(:valid_open_enrollment_end_on)    { valid_open_enrollment_start_on + 10.days }

    let(:plan_year) do
      py = PlanYear.new({
        employer_profile: employer_profile,
        start_on: valid_plan_year_start_on,
        end_on: valid_plan_year_end_on,
        open_enrollment_start_on: valid_open_enrollment_start_on,
        open_enrollment_end_on: valid_open_enrollment_end_on
        })

      py.aasm_state = "active"
      py.benefit_groups = [benefit_group]
      py.save
      py
    end

    it "should be valid" do
      expect(plan_year.valid?).to be_truthy
    end
  end

  context "renewing employer plan year" do

    let!(:employer_profile) { FactoryGirl.build(:employer_profile)}

    let(:plan_year_start_on) { Date.new(2016, 11, 1) }
    let(:plan_year_end_on) { plan_year_start_on + 1.year - 1.day }
    let(:open_enrollment_start_on)  { plan_year_start_on.prev_month }
    let(:open_enrollment_end_on)    { open_enrollment_start_on + 12.days }

    let(:renewal_py_state) { 'renewing_draft' }

    let!(:renewing_plan_year)                     { py = FactoryGirl.create(:plan_year,
                                                      start_on: plan_year_start_on,
                                                      end_on: plan_year_end_on,
                                                      open_enrollment_start_on: open_enrollment_start_on,
                                                      open_enrollment_end_on: open_enrollment_end_on,
                                                      employer_profile: employer_profile,
                                                      aasm_state: renewal_py_state
                                                    )

                                                    py.benefit_groups = [FactoryGirl.build(:benefit_group, title: "blue collar", plan_year: py)]
                                                    py.save(:validate => false)
                                                    py
                                                  }

    let!(:plan_year)                              { py = FactoryGirl.create(:plan_year,
                                                      start_on: plan_year_start_on - 1.year,
                                                      end_on: plan_year_end_on - 1.year,
                                                      open_enrollment_start_on: open_enrollment_start_on - 1.year,
                                                      open_enrollment_end_on: open_enrollment_end_on - 1.year - 3.days,
                                                      employer_profile: employer_profile,
                                                      aasm_state: 'active'
                                                    )

                                                    py.benefit_groups = [FactoryGirl.build(:benefit_group, title: "blue collar", plan_year: py)]
                                                    py.save(:validate => false)
                                                    py
                                                  }

    context 'before publish due date' do

      before do
        TimeKeeper.set_date_of_record_unprotected!(Date.new(2016, 10, Settings.aca.shop_market.renewal_application.publish_due_day_of_month))
      end

      it 'should be publishable' do
        expect(renewing_plan_year.renewing_draft?).to be_truthy
        expect(renewing_plan_year.may_publish?).to be_truthy
        renewing_plan_year.publish!
        renewing_plan_year.reload
        expect(renewing_plan_year.renewing_enrolling?).to be_truthy
      end
    end

    context 'on force publish date' do

      before do
        TimeKeeper.set_date_of_record_unprotected!(Date.new(2016, 10, Settings.aca.shop_market.renewal_application.force_publish_day_of_month))
      end

      it 'should be force publishable' do
        expect(renewing_plan_year.renewing_draft?).to be_truthy
        expect(renewing_plan_year.may_force_publish?).to be_truthy
        renewing_plan_year.force_publish!
        renewing_plan_year.reload
        expect(renewing_plan_year.renewing_enrolling?).to be_truthy
        expect(renewing_plan_year.valid?).to be_truthy
      end
    end

    context 'when plan year reverted' do

      context 'employee has enrollment under renewing plan year'  do

        let(:renewal_py_state) { 'renewing_enrolling' }

        let(:census_employee){
          employee = FactoryGirl.create :census_employee, employer_profile: employer_profile
          employee.add_renew_benefit_group_assignment renewing_plan_year.benefit_groups.first
          employee
        }

        let(:family) {
          person = FactoryGirl.create(:person, last_name: census_employee.last_name, first_name: census_employee.first_name)
          employee_role = FactoryGirl.create(:employee_role, person: person, census_employee: census_employee, employer_profile: employer_profile)
          census_employee.update_attributes({employee_role: employee_role})
          Family.find_or_build_from_employee_role(employee_role)
        }

        let!(:plan) {
          FactoryGirl.create(:plan, :with_premium_tables, market: 'shop', metal_level: 'silver', active_year: renewing_plan_year.start_on.year, hios_id: "11111111122301-01", csr_variant_id: "01")
        }

        let(:person) { family.family_members.first.person }
        let(:passive_renewal) { FactoryGirl.create(:hbx_enrollment,
                       household: family.active_household,
                       coverage_kind: "health",
                       effective_on: renewing_plan_year.start_on,
                       enrollment_kind: "open_enrollment",
                       kind: "employer_sponsored",
                       benefit_group_id: renewing_plan_year.benefit_groups.first.id,
                       employee_role_id: person.active_employee_roles.first.id,
                       benefit_group_assignment_id: census_employee.renewal_benefit_group_assignment.id,
                       plan_id: plan.id,
                       aasm_state: 'auto_renewing'
                       ) }

        it 'should cancel enrollments under reverted plan year' do
          expect(passive_renewal.auto_renewing?).to be_truthy
          renewing_plan_year.revert_renewal!
          passive_renewal.reload
          expect(passive_renewal.coverage_canceled?).to be_truthy
        end
      end
    end
  end

  context '.carriers_offered' do

    let!(:employer_profile) { create(:employer_with_planyear, plan_year_state: 'active', start_on: TimeKeeper.date_of_record.next_month.beginning_of_month)}
    let(:plan_year) { employer_profile.published_plan_year }
    let(:carrier_profile)         { FactoryGirl.create(:carrier_profile) }
    let(:carrier_profile_1)       { FactoryGirl.create(:carrier_profile) }
    let!(:silver_ref_plan)   { FactoryGirl.create(:plan, :with_premium_tables, carrier_profile: carrier_profile) }
    let!(:gold_ref_plan)     { FactoryGirl.create(:plan, :with_premium_tables, carrier_profile: carrier_profile_1) }
    let(:silver_bg) { FactoryGirl.build(:benefit_group, title: "silver offerings", plan_year: plan_year, reference_plan_id: silver_ref_plan.id, plan_option_kind: 'single_carrier')}
    let(:gold_bg) { FactoryGirl.build(:benefit_group, title: "gold offerings", plan_year: plan_year, reference_plan_id: gold_ref_plan.id, plan_option_kind: 'single_carrier')}

    before do
      plan_year.benefit_groups = [silver_bg, gold_bg]
      plan_year.save(:validate => false)
    end

    context '.carriers_offered' do

      it "should return carriers offered on multiple benefit groups" do
        expect(plan_year.carriers_offered).to eq [carrier_profile.id, carrier_profile_1.id]
      end
    end
  end
end

describe PlanYear, '.update_employee_benefit_packages', type: :model, dbclean: :after_all do
  let(:start_on) { TimeKeeper.date_of_record.beginning_of_month }
  let!(:employer_profile) { create(:employer_with_planyear, plan_year_state: 'active', start_on: start_on)}
  let(:benefit_group) { employer_profile.published_plan_year.benefit_groups.first}
  let!(:census_employee){
    employee = FactoryGirl.create :census_employee, employer_profile: employer_profile
    employee.add_benefit_group_assignment benefit_group, benefit_group.start_on
    employee
  }

  context 'when plan year begin date changed' do
    let(:modified_start_on) { TimeKeeper.date_of_record.next_month.beginning_of_month }
    let(:modified_end_on) { TimeKeeper.date_of_record.next_month.beginning_of_month }

    it "should update benefit group assignment dates" do
      expect(census_employee.active_benefit_group_assignment.start_on).to eq start_on

      plan_year = employer_profile.active_plan_year
      plan_year.start_on = modified_start_on
      plan_year.end_on = modified_end_on
      plan_year.save
      census_employee.reload

      expect(census_employee.active_benefit_group_assignment.start_on).to eq modified_start_on
    end
    it "should update benefit group assignment dates" do
      plan_year = employer_profile.active_plan_year
      plan_year.start_on = modified_start_on
      plan_year.end_on = modified_end_on
      plan_year.save
      census_employee.reload
      expect(plan_year.census_employees_within_play_year.size).to eq 1
      census_employee.update_attributes(aasm_state:'employment_terminated')
      expect(plan_year.census_employees_within_play_year.size).to eq 0
    end
  end
end

describe PlanYear, '.terminate_employee_benefit_packages', type: :model, dbclean: :after_each do
  let(:person) {FactoryGirl.create(:person)}
  let(:family) { FactoryGirl.build(:family, :with_primary_family_member)}
  let(:start_on) { TimeKeeper.date_of_record.beginning_of_month }
  let(:employer_profile) { FactoryGirl.create(:employer_profile, aasm_state: "enrolled") }
  let(:employee_role1) {FactoryGirl.create(:employee_role, person: person, employer_profile: employer_profile)}
  let!(:plan_year) {FactoryGirl.create(:plan_year, employer_profile: employer_profile, aasm_state: 'active', start_on: start_on)}
  let!(:benefit_group) {FactoryGirl.create(:benefit_group, plan_year: plan_year)}
  let(:benefit_group_assignment1) {FactoryGirl.build(:benefit_group_assignment, benefit_group: benefit_group, end_on: plan_year.end_on)}
  let!(:census_employee) { FactoryGirl.create(:census_employee, benefit_group_assignments: [benefit_group_assignment1],employee_role_id: employee_role1.id,employer_profile_id: employer_profile.id) }
  let(:new_end_on) { TimeKeeper.date_of_record.prev_day }
  let!(:census_employee1){FactoryGirl.create(:census_employee, :termination_details, benefit_group_assignments: [benefit_group_assignment1],employee_role_id: employee_role1.id,employer_profile_id: employer_profile.id)}
  let!(:enrollment) { FactoryGirl.create(:hbx_enrollment, effective_on: start_on, employee_role_id: employee_role1.id, household: family.active_household, benefit_group_id: benefit_group.id, aasm_state: 'coverage_selected', employee_role: census_employee.employee_role)}

  before do
    employee_role1.census_employee = census_employee
    employee_role1.save
    plan_year.terminate_plan_year(new_end_on, TimeKeeper.date_of_record, 'nonpayment', false, 'nonpayment', )
    plan_year.reload
    benefit_group_assignment1.reload
  end

  context 'when plan year is terminated' do
    it "should include only the non-terminated census employee" do
      census_employee1.update_attributes(aasm_state:'employment_terminated')
      expect(employer_profile.census_employees.size).to eq 2
      expect(plan_year.census_employees_within_play_year.size).to eq 1
    end
    it "should terminate employee benefit group assignments" do
      expect(benefit_group_assignment1.end_on).to eq plan_year.end_on
    end

    it "should save enrollment termiantion reason" do
      enrollment.reload
      expect(enrollment.terminate_reason).to eq "nonpayment"
    end
  end
end

describe PlanYear, 'Cancel plan year', type: :model, dbclean: :after_each do

  let(:benefit_group) { FactoryGirl.build(:benefit_group)}
  let(:benefit_group1) { FactoryGirl.build(:benefit_group)}
  let!(:active_plan_year)  { FactoryGirl.create(:plan_year, start_on: TimeKeeper.date_of_record.next_month.beginning_of_month - 1.year, end_on: TimeKeeper.date_of_record.end_of_month, aasm_state: 'active',benefit_groups:[benefit_group]) }
  let!(:renewal_plan_year)  { FactoryGirl.create(:plan_year,start_on: TimeKeeper.date_of_record.next_month.beginning_of_month + 1.months, end_on: (TimeKeeper.date_of_record.next_month + 1.year).end_of_month, aasm_state:'renewing_enrolling',benefit_groups:[benefit_group1]) }
  let(:employer_profile)     { FactoryGirl.build(:employer_profile, plan_years: [active_plan_year,renewal_plan_year]) }
  let(:organization) { FactoryGirl.create(:organization, employer_profile:employer_profile)}
  let(:family) { FactoryGirl.build(:family, :with_primary_family_member)}
  let(:active_benefit_group_assignment) {FactoryGirl.build(:benefit_group_assignment, start_on: active_plan_year.start_on, benefit_group_id: benefit_group.id)}
  let(:renewal_benefit_group_assignment) {FactoryGirl.build(:benefit_group_assignment, start_on: renewal_plan_year.start_on, benefit_group_id: benefit_group1.id)}
  let(:census_employee)   { FactoryGirl.create(:census_employee, employer_profile: employer_profile, benefit_group_assignments:[active_benefit_group_assignment, renewal_benefit_group_assignment]) }
  let(:census_employee1)   { FactoryGirl.create(:census_employee, :termination_details, employer_profile: employer_profile, benefit_group_assignments:[active_benefit_group_assignment, renewal_benefit_group_assignment]) }
  let(:employee_role)   { FactoryGirl.build(:employee_role, employer_profile: employer_profile )}
  let(:enrollment) { FactoryGirl.build(:hbx_enrollment, household: family.active_household, employee_role: census_employee.employee_role)}
  let(:enrollment2) { FactoryGirl.build(:hbx_enrollment, household: family.active_household, employee_role: census_employee.employee_role,aasm_state:'auto_renewing')}

  context 'when initial plan year is canceled' do

    before do
      enrollment.update_attributes(benefit_group_id: benefit_group.id, aasm_state:'coverage_selected')
      active_benefit_group_assignment.update_attributes(hbx_enrollment_id:enrollment.id,aasm_state:'coverage_selected')
      active_plan_year.cancel!
      active_benefit_group_assignment.reload
    end

    context '.cancel_employee_benefit_packages' do
      it "should include only the non-terminated census employee" do
      census_employee1.update_attributes(aasm_state:'employment_terminated')
      expect(employer_profile.census_employees.size).to eq 2
      expect(active_plan_year.census_employees_within_play_year.size).to eq 1
    end

      it "should cancel employee benefit group assignments" do
        expect(active_benefit_group_assignment.aasm_state).to eq "initialized"
      end

      it "should deactivate benefit group assignment" do
        expect(active_benefit_group_assignment.is_active).to be_falsey
      end
    end

    context '.cancel_employee_enrollments' do
      it "should cancel enrollment" do
        enrollment.reload
        expect(enrollment.aasm_state).to eq "coverage_canceled"
      end
    end

    context '.update_end_date' do
      it "should update the initial plan year end date" do
        expect(active_plan_year.end_on).to eq active_plan_year.start_on
      end
    end
  end

  context 'when plan year is canceled' do

    before do
      enrollment.update_attributes(benefit_group_id: benefit_group.id, aasm_state:'inactive')
      active_benefit_group_assignment.update_attributes(hbx_enrollment_id:enrollment.id,aasm_state:'coverage_selected')
      active_plan_year.cancel!
      active_benefit_group_assignment.reload
    end

    it "should cancel waived enrollment" do
      enrollment.reload
      expect(enrollment.aasm_state).to eq "coverage_canceled"
    end
  end

  context 'when renewal plan year is canceled' do

    before do
      enrollment.update_attributes(benefit_group_id: benefit_group.id, aasm_state:'coverage_selected')
      enrollment2.update_attributes!(benefit_group_id: benefit_group1.id, aasm_state:'auto_renewing')
      active_benefit_group_assignment.update_attributes(hbx_enrollment_id:enrollment.id,aasm_state:'coverage_selected')
      renewal_benefit_group_assignment.update_attributes(hbx_enrollment_id:enrollment2.id, is_active:true, aasm_state:'coverage_renewing')
      renewal_plan_year.cancel_renewal!
      renewal_benefit_group_assignment.reload
    end

    context '.cancel_employee_benefit_packages' do

      it 'should not cancel active plan year benefit group assignments' do
        expect(active_benefit_group_assignment.aasm_state).to eq "coverage_selected"
      end

      it 'should be active' do
        expect(active_benefit_group_assignment.is_active).to be_truthy
      end

      it "should cancel employee renewing benefit group assignments" do
        expect(renewal_benefit_group_assignment.aasm_state).to eq "initialized"
      end

      it "should deactivate renewing benefit group assignment" do
        expect(renewal_benefit_group_assignment.is_active).to be_falsey
      end
    end

    context '.update_end_date' do
      it "should update the renewal plan year end date" do
        expect(renewal_plan_year.end_on).to eq renewal_plan_year.start_on
      end
    end

    context '.cancel_employee_enrollments' do

      it "should cancel renewing enrollment" do
        enrollment2.reload
        expect(enrollment2.aasm_state).to eq "coverage_canceled"
      end

      it "should not cancel active enrollment" do
        expect(enrollment.aasm_state).to eq "coverage_selected"
      end
    end
  end
end

describe PlanYear, '.enrollments_for_plan_year', type: :model, dbclean: :after_each do
  let(:person) { FactoryGirl.create(:person, :with_family)}
  let(:start_on) { TimeKeeper.date_of_record.beginning_of_month }
  let(:employer_profile) { FactoryGirl.create(:employer_profile) }
  let(:employee_role) {FactoryGirl.create(:employee_role, person: person, employer_profile: employer_profile)}
  let!(:plan_year) {FactoryGirl.create(:plan_year, employer_profile: employer_profile, aasm_state: 'active', start_on: start_on)}
  let!(:benefit_group) {FactoryGirl.create(:benefit_group, plan_year: plan_year)}
  let(:benefit_group_assignment1) {FactoryGirl.build(:benefit_group_assignment, benefit_group: benefit_group, end_on: plan_year.end_on)}
  let!(:census_employee) { FactoryGirl.create(:census_employee, benefit_group_assignments: [benefit_group_assignment1],employee_role_id: employee_role.id,employer_profile_id: employer_profile.id) }
  let(:household) { FactoryGirl.create(:household, family: person.primary_family)}
  let!(:hbx_enrollment) { FactoryGirl.create(:hbx_enrollment, household: census_employee.employee_role.person.primary_family.households.first, benefit_group_id: benefit_group.id)}

  it "should return enrollments for the plan year" do
    expect(plan_year.enrollments_for_plan_year).to eq [hbx_enrollment]
  end
end

describe PlanYear, '.terminate_employee_enrollments', type: :model, dbclean: :after_each do
  let(:person) { FactoryGirl.create(:person, :with_family)}
  let(:start_on) { TimeKeeper.date_of_record.beginning_of_month.prev_month }
  let(:employer_profile) { FactoryGirl.create(:employer_profile) }
  let(:employee_role) {FactoryGirl.create(:employee_role, person: person, employer_profile: employer_profile)}
  let!(:plan_year) {FactoryGirl.create(:plan_year, employer_profile: employer_profile, aasm_state: 'active', start_on: start_on)}
  let!(:benefit_group) {FactoryGirl.create(:benefit_group, plan_year: plan_year)}
  let(:benefit_group_assignment1) {FactoryGirl.build(:benefit_group_assignment, benefit_group: benefit_group, end_on: plan_year.end_on)}
  let!(:census_employee) { FactoryGirl.create(:census_employee, benefit_group_assignments: [benefit_group_assignment1],employee_role_id: employee_role.id,employer_profile_id: employer_profile.id) }
  let(:household) { FactoryGirl.create(:household, family: person.primary_family)}
  let!(:hbx_enrollment) { FactoryGirl.create(:hbx_enrollment, household: census_employee.employee_role.person.primary_family.households.first, benefit_group_id: benefit_group.id, employee_role_id: employee_role.id)}

  py_termination_dates = [TimeKeeper.date_of_record - 8.days, TimeKeeper.date_of_record, TimeKeeper.date_of_record + 14.days]

  context 'when plan year is terminated' do

    before do
      employee_role.census_employee = census_employee
      employee_role.save
      TimeKeeper.set_date_of_record_unprotected!(start_on.next_month)
      employee_role.update_attributes(census_employee_id: census_employee.id)
    end

    after do
      TimeKeeper.set_date_of_record_unprotected!(Date.today)
    end

    py_termination_dates.each do |py_end_on|
      it "should move the enrollment to coverage terminated/pending status" do
        plan_year.terminate_plan_year(py_end_on, TimeKeeper.date_of_record, 'voluntary', false, 'nonpayment')
        hbx_enrollment.reload
        if py_end_on < TimeKeeper.date_of_record
          expect(hbx_enrollment.aasm_state).to eq 'coverage_terminated'
        else
          expect(hbx_enrollment.aasm_state).to eq 'coverage_termination_pending'
        end
        expect(hbx_enrollment.terminate_reason).to eq 'nonpayment'
      end
    end

    it "should move the enrollment to canceled state if enrollment effective_on > py_end_on" do
      hbx_enrollment.update_attributes!(effective_on: start_on + 2.months)
      plan_year.terminate_plan_year(py_termination_dates[1], TimeKeeper.date_of_record, 'voluntary', false, 'nonpayment')
      hbx_enrollment.reload
      expect(hbx_enrollment.aasm_state).to eq 'coverage_canceled'
      expect(hbx_enrollment.terminate_reason).to eq nil
    end
  end

  context 'when coverage_termination_pending enrollments are present', dbclean: :after_each do
    let(:terminated_on) { start_on + 2.months }

    before do
      hbx_enrollment.update_attributes(aasm_state: "coverage_termination_pending", terminated_on: terminated_on)
      TimeKeeper.set_date_of_record_unprotected!(start_on.next_month)
    end

    after do
      TimeKeeper.set_date_of_record_unprotected!(Date.today)
    end

    context 'when hbx_enrollment terminated_on > plan_year_end_on' do

      let(:plan_year_end_on) { terminated_on.prev_day }

      it "should update terminated_on on hbx_enrollment" do
        plan_year.terminate_employee_enrollments(plan_year_end_on, {enrollment_term_reason: 'nonpayment'})
        expect(hbx_enrollment.reload.terminated_on).to eq plan_year_end_on
        expect(hbx_enrollment.reload.terminate_reason).to eq 'nonpayment'
      end
    end

    context 'when hbx_enrollment terminated_on < plan_year_end_on' do

      let(:plan_year_end_on) { terminated_on.next_day }

      it "should NOT update terminated_on on hbx_enrollment" do
        plan_year.terminate_employee_enrollments(plan_year_end_on, {enrollment_term_reason: 'nonpayment'})
        expect(hbx_enrollment.reload.terminated_on).to eq terminated_on
        expect(hbx_enrollment.reload.terminate_reason).to eq nil
      end
    end
  end

  context 'when coverage_terminated enrollments are present', dbclean: :after_each do
    let(:terminated_on) { start_on + 2.months }

    before do
      hbx_enrollment.update_attributes(aasm_state: "coverage_terminated", terminated_on: terminated_on)
      TimeKeeper.set_date_of_record_unprotected!(start_on.next_month)
    end

    after do
      TimeKeeper.set_date_of_record_unprotected!(Date.today)
    end

    context 'when hbx_enrollment terminated_on < plan_year_end_on' do

      let(:plan_year_end_on) { terminated_on.next_day }

      it "should NOT update terminated_on on hbx_enrollment" do
        plan_year.terminate_employee_enrollments(plan_year_end_on, {enrollment_term_reason: 'nonpayment'})
        expect(hbx_enrollment.reload.terminated_on).to eq terminated_on
        expect(hbx_enrollment.reload.terminate_reason).to eq nil
      end
    end
  end
end

describe "notify_employer_py_voluntary_terminate" do
  context "notify employer plan year termination " do
    let!(:plan_year) {FactoryGirl.build(:plan_year, termination_kind: 'voluntary', aasm_state:'terminated')}
    let!(:employer_profile) { FactoryGirl.create(:employer_profile,plan_years:[plan_year]) }

    it "should notify event" do
      expect(plan_year).to receive(:notify).with("acapi.info.events.employer.benefit_coverage_period_terminated_voluntary", {employer_id: plan_year.employer_profile.hbx_id, event_name: "benefit_coverage_period_terminated_voluntary"})
      plan_year.send(:notify_employer_py_terminate, true)
    end

    it "should not notify event" do
      expect(plan_year).to receive(:notify).exactly(0).times
      plan_year.send(:notify_employer_py_terminate, false)
    end
  end
end

describe "notify_employer_py_nonpayment_terminate" do
  context "notify employer plan year termination " do
    let!(:plan_year) {FactoryGirl.build(:plan_year, termination_kind: "nonpayment", aasm_state:'terminated')}
    let!(:employer_profile) { FactoryGirl.create(:employer_profile,plan_years:[plan_year]) }

    it "should notify event" do
      expect(plan_year).to receive(:notify).with("acapi.info.events.employer.benefit_coverage_period_terminated_nonpayment", {employer_id: plan_year.employer_profile.hbx_id, event_name: "benefit_coverage_period_terminated_nonpayment"})
      plan_year.send(:notify_employer_py_terminate, true)
    end

    it "should not notify event" do
      expect(plan_year).to receive(:notify).exactly(0).times
      plan_year.send(:notify_employer_py_terminate, false)
    end
  end
end

describe "notify_employer_py_cancellation" do
  context "notify employer plan year cancellation " do
    let(:plan_year) {FactoryGirl.build(:plan_year,aasm_state:'active')}
    let(:renewal_plan_year) {FactoryGirl.build(:plan_year,start_on:TimeKeeper.date_of_record.beginning_of_month.next_month, aasm_state:'renewing_enrolled')}
    let(:employer_profile) { FactoryGirl.create(:employer_profile,plan_years:[plan_year, renewal_plan_year]) }

    it "should notify event" do
      expect(plan_year).to receive(:notify).with("acapi.info.events.employer.benefit_coverage_renewal_carrier_dropped", {employer_id: plan_year.employer_profile.hbx_id, plan_year_id:plan_year.id, event_name: "benefit_coverage_renewal_carrier_dropped"})
      plan_year.cancel!(true)
    end

    it "should not notify event, when renewal plan year canceled and open enrollment not compeleted" do
      expect(renewal_plan_year).to receive(:notify).exactly(0).times
      renewal_plan_year.cancel_renewal!(false)
    end

    it "should notify event, when renewal plan year canceled" do
      allow(renewal_plan_year).to receive(:open_enrollment_completed?).and_return true
      allow(renewal_plan_year).to receive(:past_transmission_threshold?).and_return true
      expect(renewal_plan_year).to receive(:notify).with("acapi.info.events.employer.benefit_coverage_renewal_carrier_dropped", {employer_id: renewal_plan_year.employer_profile.hbx_id, plan_year_id:renewal_plan_year.id, event_name: "benefit_coverage_renewal_carrier_dropped"})
      renewal_plan_year.cancel_renewal!(true)
    end

    it "should not notify event" do
      expect(plan_year).to receive(:notify).exactly(0).times
      plan_year.revert_renewal!(false)
    end


    context 'when wavied enrollment cancelled should not notify enrollment event.' do
      let(:family) { FactoryGirl.create(:family, :with_primary_family_member)}
      let(:enrollment) { FactoryGirl.create(:hbx_enrollment, household: family.active_household, aasm_state:'inactive')}

      it "should cancel waived enrollment" do
        expect(enrollment.aasm_state).to eq "inactive"
        allow(plan_year).to receive(:enrollments_for_plan_year).and_return [enrollment]
        expect(plan_year).to receive(:notify).exactly(0).times
        plan_year.cancel_employee_enrollments( true)
        expect(enrollment.aasm_state).to eq "coverage_canceled"
      end
    end
  end
end

describe '.extend_open_enrollment' do
  let(:current_effective_date) { Date.new(Date.today.year, 4, 1) }
  let(:today) { current_effective_date - 7.days }
  let!(:employer_profile) {FactoryGirl.create(:employer_profile)}
  let!(:plan_year) {FactoryGirl.create(:plan_year, employer_profile: employer_profile, aasm_state: aasm_state, start_on: current_effective_date)}

  before(:each) do
    TimeKeeper.set_date_of_record_unprotected!(today)
  end

  after(:each) do
    TimeKeeper.set_date_of_record_unprotected!(Date.today)
  end

  context 'when plan year is ineligible' do
    let(:aasm_state) { :application_ineligible }
    let(:today) { current_effective_date - 7.days }
    let(:oe_end_date) { current_effective_date - 5.days }

    it 'should extend open enrollment' do
      expect(plan_year.aasm_state).to eq "application_ineligible"
      plan_year.extend_open_enrollment(oe_end_date)
      plan_year.reload
      expect(plan_year.aasm_state).to eq "enrollment_extended"
      expect(plan_year.open_enrollment_end_on).to eq oe_end_date
    end
  end

  context 'when plan year canceled due to ineligibility' do
    let(:aasm_state) { :canceled }
    let(:today) { current_effective_date + 2.days }
    let(:oe_end_date) { current_effective_date + 5.days }

    it 'should extend open enrollment' do
      expect(plan_year.aasm_state).to eq "canceled"
      plan_year.extend_open_enrollment(oe_end_date)
      plan_year.reload
      expect(plan_year.aasm_state).to eq "enrollment_extended"
      expect(plan_year.open_enrollment_end_on).to eq oe_end_date
    end
  end

  context 'when plan year canceled due to ineligibility' do
    let(:aasm_state) { :renewing_canceled }
    let(:today) { current_effective_date + 2.days }
    let(:oe_end_date) { current_effective_date + 5.days }

    it 'should extend open enrollment' do
      expect(plan_year.aasm_state).to eq "renewing_canceled"
      plan_year.extend_open_enrollment(oe_end_date)
      plan_year.reload
      expect(plan_year.aasm_state).to eq "renewing_enrollment_extended"
      expect(plan_year.open_enrollment_end_on).to eq oe_end_date
    end
  end

  context 'when plan year is in open enrollment' do
    let(:aasm_state) { :enrolling }
    let(:today) { current_effective_date - 8.days }
    let(:oe_end_date) { current_effective_date - 5.days }

    it 'should extend open enrollment' do
      expect(plan_year.aasm_state).to eq "enrolling"
      plan_year.extend_open_enrollment(oe_end_date)
      plan_year.reload
      expect(plan_year.aasm_state).to eq "enrollment_extended"
      expect(plan_year.open_enrollment_end_on).to eq oe_end_date
    end
  end

  context 'when plan year is in open enrollment' do
    let(:aasm_state) { :renewing_enrolling }
    let(:today) { current_effective_date - 8.days }
    let(:oe_end_date) { current_effective_date - 5.days }

    it 'should extend open enrollment' do
      expect(plan_year.aasm_state).to eq "renewing_enrolling"
      plan_year.extend_open_enrollment(oe_end_date)
      plan_year.reload
      expect(plan_year.aasm_state).to eq "renewing_enrollment_extended"
      expect(plan_year.open_enrollment_end_on).to eq oe_end_date
    end
  end

  context 'when plan year open enrollment entended' do
    let(:aasm_state) { :enrollment_extended }
    let(:today) { current_effective_date - 13.days }
    let(:oe_end_date) { current_effective_date - 5.days }

    it 'should extend open enrollment' do
      expect(plan_year.aasm_state).to eq "enrollment_extended"
      plan_year.extend_open_enrollment(oe_end_date)
      plan_year.reload
      expect(plan_year.aasm_state).to eq "enrollment_extended"
      expect(plan_year.open_enrollment_end_on).to eq oe_end_date
    end
  end
end

describe ".end_open_enrollment" do
  let(:oe_end_on) { TimeKeeper.date_of_record + 2.days }
  let(:current_effective_date) { Date.new(TimeKeeper.date_of_record.year, 4, 1) }
  let(:aasm_state) { :enrollment_extended }
  let!(:employer_profile) {FactoryGirl.create(:employer_profile)}
  let!(:plan_year) {FactoryGirl.create(:plan_year, employer_profile: employer_profile, aasm_state: aasm_state, start_on: current_effective_date)}

  before(:each) do
    TimeKeeper.set_date_of_record_unprotected!(Date.new(Date.today.year, 3, 24))
  end

  after(:each) do
    TimeKeeper.set_date_of_record_unprotected!(Date.today)
  end

  context "open enrollment close invoked with earlier date" do
    before do
      plan_year.update(open_enrollment_end_on: oe_end_on)
      allow(plan_year).to receive(:is_enrollment_valid?).and_return(true)
    end

    it "should close open enrollment and reset OE end date" do
      expect(plan_year.open_enrollment_end_on).to eq oe_end_on
      plan_year.end_open_enrollment(TimeKeeper.date_of_record)
      plan_year.reload
      expect(plan_year.open_enrollment_end_on).to eq TimeKeeper.date_of_record
      expect(plan_year.aasm_state).to eq "enrolled"
    end
  end
end
