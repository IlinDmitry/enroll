require "rails_helper"

describe CensusEmployeePolicy do
  subject { described_class }
  let(:employer_profile){ FactoryGirl.create(:employer_profile)}
  let(:person) { FactoryGirl.create(:person) }
  let(:admin_person) { FactoryGirl.create(:person, :with_hbx_staff_role) }
  let(:broker_person) { FactoryGirl.create(:person, :with_broker_role) }
  let(:employer_staff_person) {FactoryGirl.create(:person,:with_employer_staff_role)}
  let(:general_agency_person) {FactoryGril.create(:person,:with_general_agency_staff_role)}

  before do 
    allow_any_instance_of(CensusEmployee).to receive(:generate_and_deliver_checkbook_url).and_return(true)
  end

  permissions :delink? do
    context "already linked" do
      let(:employee) { FactoryGirl.build(:census_employee, employer_profile_id: employer_profile.id, aasm_state: "employee_role_linked") }

      context "with perosn with appropriate roles" do
        it "grants access when hbx_staff" do
          expect(subject).to permit(FactoryGirl.create(:user, :hbx_staff, person: admin_person), employee)
        end

        it "grants access when broker" do
          expect(subject).to permit(FactoryGirl.create(:user, :broker, person: broker_person), employee)
        end

        it "grants access when broker_agency_staff" do
          expect(subject).to permit(FactoryGirl.create(:user, :broker_agency_staff, person: broker_person), employee)
        end
      end

      it "denies access when normal user" do
        expect(subject).not_to permit(FactoryGirl.create(:user), employee)
      end
    end

    context "not linked" do
      let(:employee) { FactoryGirl.create(:census_employee, employer_profile_id: employer_profile.id, aasm_state: "eligible") }

      it "denies access when hbx_staff" do
        expect(subject).not_to permit(FactoryGirl.create(:user, :hbx_staff, person: admin_person), employee)
      end

      it "denies access when broker" do
        expect(subject).not_to permit(FactoryGirl.create(:user, :broker, person: broker_person), employee)
      end

      it "denies access when broker_agency_staff" do
        expect(subject).not_to permit(FactoryGirl.create(:user, :broker_agency_staff, person: broker_person), employee)
      end

      it "denies access when normal user" do
        expect(subject).not_to permit(FactoryGirl.create(:user, person: person), employee)
      end
    end
  end

  permissions :update? do
    let(:employee) { FactoryGirl.create(:census_employee, employer_profile_id: employer_profile.id, aasm_state: "eligible") }

    context "when is hbx_staff user" do
      let(:user) { FactoryGirl.create(:user, :hbx_staff, person: admin_person) }

      it "grants access when change dob" do
        employee.dob = TimeKeeper.date_of_record
        expect(subject).to permit(user, employee)
      end

      it "grants access when change ssn" do
        employee.ssn = "123321456"
        expect(subject).to permit(user, employee)
      end
    end

    context "when is normal user" do
      let(:user) { FactoryGirl.create(:user) }

      it "denies access when change dob" do
        employee.dob = TimeKeeper.date_of_record
        expect(subject).not_to permit(user, employee)
      end

      it "denies access when change ssn" do
        employee.ssn = "123321456"
        expect(subject).not_to permit(user, employee)
      end
    end

    context "when is broker user" do
      let(:user) { FactoryGirl.create(:user, :broker, person: person) }

      context "current user is broker of employer_profile" do
        before :each do
          allow(employer_profile).to receive(:active_broker).and_return person
          allow(employee).to receive(:employer_profile).and_return employer_profile
        end

        it "grants access when change dob" do
          employee.dob = TimeKeeper.date_of_record
          expect(subject).to permit(user, employee)
        end

        it "grants access when change ssn" do
          employee.ssn = "123321456"
          expect(subject).to permit(user, employee)
        end
      end

      context "current user is not broker of employer_profile" do
        before :each do
          allow(employer_profile).to receive(:active_broker).and_return FactoryGirl.build(:person)
          allow(employee).to receive(:employer_profile).and_return employer_profile
        end

        it "denies access when change dob" do
          employee.dob = TimeKeeper.date_of_record
          expect(subject).not_to permit(user, employee)
        end

        it "denies access when change ssn" do
          employee.ssn = "123321456"
          expect(subject).not_to permit(user, employee)
        end
      end
    end

    context "when is employer_staff user" do
      let(:user) { FactoryGirl.create(:user, :employer_staff) }

      context "not linked" do
        before do
          allow(employee).to receive(:eligible?).and_return(true)
        end

        context "when employee is staff of current user" do
          let(:employer_staff_role) {double(employer_profile_id: employer_profile.id)}
          let(:employer_staff_roles) { [employer_staff_role] }
          before :each do
            allow(person).to receive(:employer_staff_roles).and_return employer_staff_roles
            allow(user).to receive(:person).and_return person
            allow(employee).to receive(:employer_profile).and_return employer_profile
          end

          it "grants access when change dob" do
            employee.dob = TimeKeeper.date_of_record
            expect(subject).to permit(user, employee)
          end

          it "grants access when change ssn" do
            employee.ssn = "123321456"
            expect(subject).to permit(user, employee)
          end
        end

        context "when employee is not staff of current user" do
          let(:employer_staff_role) {double(employer_profile_id: EmployerProfile.new.id)}
          let(:employer_staff_roles) { [employer_staff_role] }
          before :each do
            allow(person).to receive(:employer_staff_roles).and_return employer_staff_roles
            allow(user).to receive(:person).and_return person
            allow(employee).to receive(:employer_profile).and_return employer_profile
          end

          it "denies access when change dob" do
            employee.dob = TimeKeeper.date_of_record
            expect(subject).not_to permit(user, employee)
          end

          it "denies access when change ssn" do
            employee.ssn = "123321456"
            expect(subject).not_to permit(user, employee)
          end
        end
      end

      context "has linked" do
        before do
          allow(employee).to receive(:eligible?).and_return(false)
        end

        context "when employee is staff of current user" do
          let(:employer_staff_role) {double(employer_profile_id: employer_profile.id)}
          let(:employer_staff_roles) { [employer_staff_role] }
          before :each do
            allow(person).to receive(:employer_staff_roles).and_return employer_staff_roles
            allow(user).to receive(:person).and_return person
            allow(employee).to receive(:employer_profile).and_return employer_profile
          end

          it "grants access when change dob" do
            employee.dob = TimeKeeper.date_of_record
            expect(subject).to permit(user, employee)
          end

          it "grants access when change ssn" do
            employee.ssn = "123321456"
            expect(subject).to permit(user, employee)
          end
        end

        context "when employee is not staff of current user" do
          let(:employer_staff_role) {double(employer_profile_id: EmployerProfile.new.id)}
          let(:employer_staff_roles) { [employer_staff_role] }
          before :each do
            allow(person).to receive(:employer_staff_roles).and_return employer_staff_roles
            allow(user).to receive(:person).and_return person
            allow(employee).to receive(:employer_profile).and_return employer_profile
          end

          it "denies access when change dob" do
            employee.dob = TimeKeeper.date_of_record
            expect(subject).not_to permit(user, employee)
          end

          it "denies access when change ssn" do
            employee.ssn = "123321456"
            expect(subject).not_to permit(user, employee)
          end
        end
      end
    end


    context "when is general agency user", dbclean: :after_each do
      let(:user) { FactoryGirl.create(:user, :general_agency_staff, person: person) }
      context "current user is broker of employer_profile" do
        let(:person) { FactoryGirl.create(:person, :with_general_agency_staff_role) }
        before do
          allow(EmployerProfile).to receive(:find_by_general_agency_profile).and_return [employee.employer_profile]
        end

        it "grants access when change dob" do
          employee.dob = TimeKeeper.date_of_record
          expect(subject).to permit(user, employee)
        end

        it "grants access when change ssn" do
          employee.ssn = "879876"
          expect(subject).to permit(user, employee)
        end
      end

      context "current user is not broker of general agency role" do
        let(:user) { FactoryGirl.create(:user, person: person) }
        it "denies access when change dob" do
          employee.dob = TimeKeeper.date_of_record
          expect(subject).not_to permit(user, employee)
        end

        it "denies access when change ssn" do
          employee.ssn = "123321456"
          expect(subject).not_to permit(user, employee)
        end
      end
    end
  end

  permissions :show? do
    let(:employee) { FactoryGirl.create(:census_employee, employer_profile_id: employer_profile.id, aasm_state: "eligible") }

    context "when is hbx_staff user" do
      let(:user) { FactoryGirl.create(:user, :hbx_staff, person: admin_person) }

      it "grants access as hbx_staff to view the page" do
        expect(subject).to permit(user, employee)
      end
    end

    context "when is normal user" do
      let(:user) { FactoryGirl.create(:user) }
      it "denies access for normal user" do
        expect(subject).not_to permit(user, employee)
      end
    end

    context "when is broker user" do
      let(:user) { FactoryGirl.create(:user, :broker, person: person) }

      context "current user is broker of employer_profile" do
        before :each do
          allow(employer_profile).to receive(:active_broker).and_return person
          allow(employee).to receive(:employer_profile).and_return employer_profile
        end
        it "grants access when for the employer's broker" do
          expect(subject).to permit(user, employee)
        end
      end

      context "current user is not broker of employer_profile" do
        before :each do
          allow(employer_profile).to receive(:active_broker).and_return FactoryGirl.build(:person)
          allow(employee).to receive(:employer_profile).and_return employer_profile
        end
        it "denies access for other broker" do
          expect(subject).not_to permit(user, employee)
        end
      end
    end

    context "when is employer_staff user" do
      let(:user) { FactoryGirl.create(:user, :employer_staff) }

      context "not linked" do
        before do
          allow(employee).to receive(:eligible?).and_return(true)
        end

        context "when employee is staff of current user" do
          let(:employer_staff_role) {double(employer_profile_id: employer_profile.id)}
          let(:employer_staff_roles) { [employer_staff_role] }
          before :each do
            allow(person).to receive(:employer_staff_roles).and_return employer_staff_roles
            allow(user).to receive(:person).and_return person
            allow(employee).to receive(:employer_profile).and_return employer_profile
          end

          it "grants access for the employer staff of current user" do
            expect(subject).to permit(user, employee)
          end
        end

        context "when employee is not staff of current user" do
          let(:employer_staff_role) {double(employer_profile_id: EmployerProfile.new.id)}
          let(:employer_staff_roles) { [employer_staff_role] }
          before :each do
            allow(person).to receive(:employer_staff_roles).and_return employer_staff_roles
            allow(user).to receive(:person).and_return person
            allow(employee).to receive(:employer_profile).and_return employer_profile
          end
          it "denies access for employer staff not for current employer" do
            expect(subject).not_to permit(user, employee)
          end
        end
      end

      context "has linked" do
        before do
          allow(employee).to receive(:eligible?).and_return(false)
        end

        context "when employee is staff of current user" do
          let(:employer_staff_role) {double(employer_profile_id: employer_profile.id)}
          let(:employer_staff_roles) { [employer_staff_role] }
          before :each do
            allow(person).to receive(:employer_staff_roles).and_return employer_staff_roles
            allow(user).to receive(:person).and_return person
            allow(employee).to receive(:employer_profile).and_return employer_profile
          end

          it "grants access when employee is staff of current user" do
            expect(subject).to permit(user, employee)
          end
        end

        context "when employee is not staff of current user" do
          let(:employer_staff_role) {double(employer_profile_id: EmployerProfile.new.id)}
          let(:employer_staff_roles) { [employer_staff_role] }
          before :each do
            allow(person).to receive(:employer_staff_roles).and_return employer_staff_roles
            allow(user).to receive(:person).and_return person
            allow(employer_staff_role).to receive(:active).and_return true
          end
          it "denies access when employee is not staff of current user" do
            expect(subject).not_to permit(user, employee)
          end
        end
      end
    end
    context "when is general agency user not linked to the employer", dbclean: :after_each do
      let(:user) { FactoryGirl.create(:user, :general_agency_staff, person: person) }
      context "current user is broker of employer_profile" do
        let(:person) { FactoryGirl.create(:person, :with_general_agency_staff_role) }
        before do
          allow(EmployerProfile).to receive(:find_by_general_agency_profile).and_return [employee.employer_profile]
        end
        it "grants access for general acency user" do
          expect(subject).not_to permit(user, employee)
        end
      end

      context "current user is not broker of general agency role" do
        let(:user) { FactoryGirl.create(:user, person: person) }
        it "denies access when user is not broker of general agency role" do
          expect(subject).not_to permit(user, employee)
        end
      end
    end
  end
end
