require 'rails_helper'
require 'aasm/rspec'

describe ConsumerRole, dbclean: :after_each do
  it { should delegate_method(:hbx_id).to :person }
  it { should delegate_method(:ssn).to :person }
  it { should delegate_method(:no_ssn).to :person}
  it { should delegate_method(:dob).to :person }
  it { should delegate_method(:gender).to :person }

  it { should delegate_method(:is_incarcerated).to :person }

  it { should delegate_method(:race).to :person }
  it { should delegate_method(:ethnicity).to :person }
  it { should delegate_method(:is_disabled).to :person }

  it { should validate_presence_of :gender }
  it { should validate_presence_of :dob }

  let(:address)       {FactoryGirl.build(:address)}
  let(:saved_person)  {FactoryGirl.create(:person, gender: "male", dob: "10/10/1974", ssn: "123456789")}
  let(:saved_person_no_ssn)  {FactoryGirl.create(:person, gender: "male", dob: "10/10/1974", ssn: "", no_ssn: '1')}
  let(:saved_person_no_ssn_invalid)  {FactoryGirl.create(:person, gender: "male", dob: "10/10/1974", ssn: "", no_ssn: '0')}
  let(:is_applicant)          { true }
  let(:citizen_error_message) { "test citizen_status is not a valid citizen status" }
  let(:person) { FactoryGirl.create(:person, :with_consumer_role) }
  describe ".new" do
    let(:valid_params) do
      {
          is_applicant: is_applicant,
          person: saved_person
      }
    end

    context "with no person" do
      let(:params) {valid_params.except(:person)}

      it "should raise" do
        expect(ConsumerRole.new(**params).valid?).to be_falsey
      end
    end

    context "with all valid arguments" do
      let(:consumer_role) { saved_person.build_consumer_role(valid_params) }

      it "should have a default value of native validation as na" do
        expect(consumer_role.native_validation).to eq "na"
      end

      it "should save" do
        expect(consumer_role.save).to be_truthy
      end

      context "and it is saved" do
        before do
          consumer_role.save
        end

        it "should be findable" do
          expect(ConsumerRole.find(consumer_role.id).id).to eq consumer_role.id
        end

        it "should have a state of unverified" do
          expect(consumer_role.aasm_state).to eq "unverified"
        end
      end
    end

    context "with all valid arguments including no ssn" do
      let(:consumer_role) { saved_person_no_ssn.build_consumer_role(valid_params) }

      it "should save" do
        expect(consumer_role.save).to be_truthy
      end

      context "and it is saved" do
        before do
          consumer_role.save
        end

        it "should be findable" do
          expect(ConsumerRole.find(consumer_role.id).id).to eq consumer_role.id
        end

        it "should have a state of verifications_pending" do
          expect(consumer_role.aasm_state).to eq "unverified"
        end
      end
    end
  end
end

describe "#find_document" do
  let(:consumer_role) {ConsumerRole.new}
  context "consumer role does not have any vlp_documents" do
    it "it creates and returns an empty document of given subject" do
      doc = consumer_role.find_document("Certificate of Citizenship")
      expect(doc).to be_a_kind_of(VlpDocument)
      expect(doc.subject).to eq("Certificate of Citizenship")
    end
  end

  context "consumer role has a vlp_document" do
    it "it returns the document" do
      document = consumer_role.vlp_documents.build({subject: "Certificate of Citizenship"})
      found_document = consumer_role.find_document("Certificate of Citizenship")
      expect(found_document).to be_a_kind_of(VlpDocument)
      expect(found_document).to eq(document)
      expect(found_document.subject).to eq("Certificate of Citizenship")
    end
  end
end

describe "#find_vlp_document_by_key" do
  let(:person) {FactoryGirl.create(:person, :with_consumer_role)}
  let(:consumer_role) { person.consumer_role }
  let(:key) {"sample-key"}
  let(:vlp_document) {VlpDocument.new({subject: "Certificate of Citizenship", identifier:"urn:openhbx:terms:v1:file_storage:s3:bucket:bucket_name##{key}"})}

  context "has a vlp_document without a file uploaded" do
    before do
      consumer_role.vlp_documents.build({subject: "Certificate of Citizenship"})
    end

    it "return no document" do
      found_document = consumer_role.find_vlp_document_by_key(key)
      expect(found_document).to be_nil
    end
  end

  context "has a vlp_document with a file uploaded" do
    before do
      consumer_role.verification_types.each{|type| type.vlp_documents << vlp_document }
    end

    it "returns vlp_document document" do
      found_document = consumer_role.find_vlp_document_by_key(key)
      expect(found_document).to eql(vlp_document)
    end
  end
end

describe "#move_identity_documents_to_outstanding" do
  let(:person) { FactoryGirl.create(:person, :with_consumer_role)}

  context "move to outstanding if initial state is unverified" do

    it "successfully updates identity and application to outstanding" do
      consumer = person.consumer_role
      consumer.move_identity_documents_to_outstanding
      expect(consumer.identity_validation). to eq 'outstanding'
      expect(consumer.application_validation). to eq 'outstanding'
    end

    it "should not update dentity and application to outstanding" do
      consumer = person.consumer_role
      consumer.identity_validation = 'valid'
      consumer.application_validation = 'valid'
      consumer.move_identity_documents_to_outstanding
      expect(consumer.identity_validation). to eq 'valid'
      expect(consumer.application_validation). to eq 'valid'
    end
  end
end

describe "#find_ridp_document_by_key" do
  let(:person) {Person.new}
  let(:consumer_role) {ConsumerRole.new({person:person})}
  let(:key) {"sample-key"}
  let(:ridp_document) {RidpDocument.new({subject: "Driver License", identifier:"urn:openhbx:terms:v1:file_storage:s3:bucket:bucket_name##{key}"})}

  context "has a ridp_document without a file uploaded" do
    before do
      consumer_role.ridp_documents.build({subject: "Driver License"})
    end

    it "return no document" do
      found_document = consumer_role.find_ridp_document_by_key(key)
      expect(found_document).to be_nil
    end
  end

  context "has a ridp_document with a file uploaded" do
    before do
      consumer_role.ridp_documents << ridp_document
    end

    it "returns ridp_document document" do
      found_document = consumer_role.find_ridp_document_by_key(key)
      expect(found_document).to eql(ridp_document)
    end
  end
end

describe "#build_nested_models_for_person" do
  let(:person) {FactoryGirl.create(:person)}
  let(:consumer_role) {ConsumerRole.new}

  before do
    allow(consumer_role).to receive(:person).and_return person
    consumer_role.build_nested_models_for_person
  end

  it "should get home and mailing address" do
    expect(person.addresses.map(&:kind)).to include "home"
    expect(person.addresses.map(&:kind)).to include 'mailing'
  end

  it "should get home and mobile phone" do
    expect(person.phones.map(&:kind)).to include "home"
    expect(person.phones.map(&:kind)).to include "mobile"
  end

  it "should get emails" do
    Email::KINDS.each do |kind|
      expect(person.emails.map(&:kind)).to include kind
    end
  end
end

describe "#latest_active_tax_household_with_year" do
  include_context "BradyBunchAfterAll"
  let(:family) { FactoryGirl.build(:family)}
  let(:consumer_role) { ConsumerRole.new }
  before :all do
    create_tax_household_for_mikes_family
    @consumer_role = mike.consumer_role
    @taxhouhold = mikes_family.latest_household.tax_households.last
  end

  it "should rerturn active taxhousehold of this year" do
    expect(@consumer_role.latest_active_tax_household_with_year(TimeKeeper.date_of_record.year, mikes_family)).to eq @taxhouhold
  end

  it "should rerturn nil when can not found taxhousehold" do
    expect(consumer_role.latest_active_tax_household_with_year(TimeKeeper.date_of_record.year, family)).to eq nil
  end
  context "vlp exist but document is NOT uploaded" do
      let(:person) {FactoryGirl.create(:person, :with_consumer_role)}
        it "returns false for vlp doc without uploaded copy" do
          unverified_types= person.verification_types.active.where(applied_roles: "consumer_role")
          unverify_count= unverified_types.reject{|a| a.type_verified? == true}.size
          expect(person.consumer_role.types_include_to_notices.count).to eq(unverify_count)
        end   
      end
  end

context "Verification process and notices" do
  let(:person) {FactoryGirl.create(:person, :with_consumer_role)}
  describe "#has_docs_for_type?" do
    before do
      person.consumer_role.vlp_documents=[]
    end
    context "vlp exist but document is NOT uploaded" do
      it "returns false for vlp doc without uploaded copy" do
        person.consumer_role.vlp_documents << FactoryGirl.build(:vlp_document, :identifier => nil )
        expect(person.consumer_role.has_docs_for_type?("Citizenship")).to be_falsey
      end
      it "returns false for Immigration type" do
        person.consumer_role.vlp_documents << FactoryGirl.build(:vlp_document, :identifier => nil, :verification_type  => "Immigration type")
        expect(person.consumer_role.has_docs_for_type?("Immigration type")).to be_falsey
      end
    end
    context "vlp with uploaded copy" do
      it "returns true if person has uploaded documents for this type" do
        person.consumer_role.vlp_documents << FactoryGirl.build(:vlp_document, :identifier => "identifier", :verification_type  => "Citizenship")
        expect(person.consumer_role.has_docs_for_type?("Citizenship")).to be_truthy
      end
      it "returns false if person has NO documents for this type" do
        person.consumer_role.vlp_documents << FactoryGirl.build(:vlp_document, :identifier => "identifier", :verification_type  => "Immigration type")
        expect(person.consumer_role.has_docs_for_type?("Immigration type")).to be_truthy
      end
    end
  end

  describe "#has_ridp_docs_for_type?" do
    before do
      person.consumer_role.ridp_documents=[]
    end
    context "ridp exist but document is NOT uploaded" do
      it "returns false for ridp doc without uploaded copy" do
        person.consumer_role.ridp_documents << FactoryGirl.build(:ridp_document, :identifier => nil )
        expect(person.consumer_role.has_ridp_docs_for_type?("Identity")).to be_falsey
      end
      it "returns false for Identity type" do
        person.consumer_role.ridp_documents << FactoryGirl.build(:ridp_document, :identifier => nil, :ridp_verification_type  => "Identity")
        expect(person.consumer_role.has_ridp_docs_for_type?("Identity")).to be_falsey
      end
    end
    context "ridp with uploaded copy" do
      it "returns true if person has uploaded documents for this type" do
        person.consumer_role.ridp_documents << FactoryGirl.build(:ridp_document, :identifier => "identifier", :ridp_verification_type  => "Identity")
        expect(person.consumer_role.has_ridp_docs_for_type?("Identity")).to be_truthy
      end
      it "returns false if person has NO documents for this type" do
        person.consumer_role.ridp_documents << FactoryGirl.build(:ridp_document, :identifier => "identifier", :ridp_verification_type  => "Identity")
        expect(person.consumer_role.has_ridp_docs_for_type?("Identity")).to be_truthy
      end
    end
  end

  describe "Native American verification" do
    shared_examples_for "ensures native american field value" do |action, state, consumer_kind, tribe, tribe_state|
      it "#{action} #{state} for #{consumer_kind}" do
        person.update_attributes!(:tribal_id=>"444444444") if tribe
        person.consumer_role.update_attributes!(:native_validation => tribe_state) if tribe_state
        expect(person.consumer_role.native_validation).to eq(state)
      end
    end
    context "native validation doesn't exist" do
      it_behaves_like "ensures native american field value", "assigns", "na", "NON native american consumer", nil, nil

      it_behaves_like "ensures native american field value", "assigns", "outstanding", "native american consumer", "444444444", nil
    end
    context "existing native validation" do
      it_behaves_like "ensures native american field value", "assigns", "pending", "pending native american consumer", "tribe", "pending"
      it_behaves_like "ensures native american field value", "doesn't change", "outstanding", "outstanding native american consumer", "tribe", "outstanding"
      it_behaves_like "ensures native american field value", "assigns", "outstanding", "na native american consumer", "tribe", "na"
    end
  end

  describe "update_ridp_verification_type private" do
    let(:consumer) { person.consumer_role }
    shared_examples_for "update ridp verification type for consumer" do |verification_type, reason|
      before do
        consumer.update_ridp_verification_type(verification_type, reason)
      end
      it "updates #{verification_type}" do
        expect(consumer.identity_verified?).to eq true
      end
    end

    it_behaves_like "update ridp verification type for consumer", "Identity", "documents in Enroll"
  end

  describe "#admin_ridp_verification_action private" do
    let(:consumer) { person.consumer_role }
    shared_examples_for "admin ridp verification actions" do |admin_action, v_type, update_reason, upd_attr, result, rejected_field|
      before do
        consumer.admin_ridp_verification_action(admin_action, v_type, update_reason)
      end
      it "updates #{v_type} as #{result} if admin clicks #{admin_action}" do
        expect(consumer.send(upd_attr)).to eq result
      end

      if admin_action == "return_for_deficiency"
        it "marks #{v_type} type as rejected" do
          expect(consumer.send(rejected_field)).to be_truthy
        end
      end
    end

    it_behaves_like "admin ridp verification actions", "verify", "Identity", "Document in EnrollApp", "identity_validation", "valid"
    it_behaves_like "admin ridp verification actions", "return_for_deficiency", "Identity", "Document in EnrollApp", "identity_validation", "outstanding", "identity_rejected"

  end

  describe "state machine" do
    let(:consumer) { person.consumer_role }
    let(:verification_types) { consumer.verification_types }
    let(:verification_attr) { OpenStruct.new({ :determined_at => Time.now, :vlp_authority => "hbx" })}
    all_states = [:unverified, :ssa_pending, :dhs_pending, :verification_outstanding, :fully_verified, :sci_verified, :verification_period_ended]
    all_citizen_states = %w(any us_citizen naturalized_citizen alien_lawfully_present lawful_permanent_resident)
    shared_examples_for "IVL state machine transitions and workflow" do |ssn, citizen, residency, residency_status, from_state, to_state, event, tribal_id = ""|
      before do
        person.ssn = ssn
        consumer.citizen_status = citizen
        consumer.is_state_resident = residency
        consumer.tribal_id = tribal_id
        consumer.local_residency_validation = residency_status
      end
      it "moves from #{from_state} to #{to_state} on #{event}" do
        expect(consumer).to transition_from(from_state).to(to_state).on_event(event.to_sym, verification_attr)
      end
    end

    context "import" do
      all_states.each do |state|
        it_behaves_like "IVL state machine transitions and workflow", nil, nil, nil, "pending", state, :fully_verified, "import!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "us_citizen", true, "valid", state, :fully_verified, "import!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "naturalized_citizen", true, "valid", state, :fully_verified, "import!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "alien_lawfully_present", true, "valid", state, :fully_verified, "import!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "lawful_permanent_resident", false, "outstanding", state, :fully_verified, "import!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "any", true, "valid", state, :fully_verified, "import!"
        it_behaves_like "IVL state machine transitions and workflow", nil, "any", false, "outstanding", state, :fully_verified, "import!"
        it "updates all verification types with callback" do
          consumer.import!
          expect(consumer.all_types_verified?).to eq true
        end
      end
    end

    context "coverage_purchased" do
      describe "citizen with ssn" do
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "us_citizen", false, "outstanding", :unverified, :ssa_pending, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "us_citizen", true, "valid", :unverified, :ssa_pending, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "naturalized_citizen", false, "outstanding", :unverified, :ssa_pending, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "naturalized_citizen", true, "valid", :unverified, :ssa_pending, "coverage_purchased!"
      end
      describe "citizen with NO ssn" do
        it_behaves_like "IVL state machine transitions and workflow", nil, "naturalized_citizen", true, "valid", :unverified, :dhs_pending, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", nil, "naturalized_citizen", false, "outstanding", :unverified, :dhs_pending, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", nil, "us_citizen", false, "outstanding", :unverified, :verification_outstanding, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", nil, "us_citizen", true,  "valid", :unverified, :verification_outstanding, "coverage_purchased!"
        it "update ssn with callback fail_ssa_for_no_ssn" do
          allow(person).to receive(:ssn).and_return nil
          allow(consumer).to receive(:citizen_status).and_return "us_citizen"
          consumer.coverage_purchased! verification_attr
          expect(consumer.ssn_validation).to eq("na")
        end
      end
      describe "immigrant with ssn" do
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "alien_lawfully_present", true, "valid", :unverified, :ssa_pending, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "alien_lawfully_present", false, "outstanding", :unverified, :ssa_pending, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "lawful_permanent_resident", false, "outstanding", :unverified, :ssa_pending, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "lawful_permanent_resident", true, "valid", :unverified, :ssa_pending, "coverage_purchased!"
      end
      describe "immigrant with NO ssn" do
        it_behaves_like "IVL state machine transitions and workflow", nil, "alien_lawfully_present", true,  "valid", :unverified, :dhs_pending, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", nil, "alien_lawfully_present", false, "outstanding", :unverified, :dhs_pending, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", nil, "lawful_permanent_resident", false, "outstanding", :unverified, :dhs_pending, "coverage_purchased!"
        it_behaves_like "IVL state machine transitions and workflow", nil, "lawful_permanent_resident", true, "valid", :unverified, :dhs_pending, "coverage_purchased!"

        context "not_lawfully_present_in_us" do

          before do
            allow(person).to receive(:ssn).and_return nil
            allow(consumer).to receive(:citizen_status).and_return "not_lawfully_present_in_us"
            consumer.lawful_presence_determination.update_attributes!(citizen_status: "not_lawfully_present_in_us")
            consumer.coverage_purchased! verification_attr
            consumer.reload
            consumer.fail_dhs! verification_attr
            consumer.reload
          end

          it "should store QNC result" do
            expect(consumer.aasm_state).not_to be "unverified"
          end
        end
      end

      describe "indian tribe member with ssn" do
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "us_citizen", true, nil, :unverified, :verification_outstanding, "coverage_purchased!", "232332431"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "us_citizen", false, nil, :unverified, :verification_outstanding, "coverage_purchased!", "232332431"
      end

      describe "indian tribe member with NO ssn" do
        it_behaves_like "IVL state machine transitions and workflow", nil, "us_citizen", true, nil, :unverified, :verification_outstanding, "coverage_purchased!", "232332431"
        it_behaves_like "IVL state machine transitions and workflow", nil, "us_citizen", false, nil, :unverified, :verification_outstanding, "coverage_purchased!", "232332431"
      end

      describe "pending verification type updates" do
        it "updates validation status to pending for unverified consumers" do
          consumer.coverage_purchased!
          expect(consumer.verification_types.map(&:validation_status)).to eq(["pending", "pending", "pending"])
        end

        it "updates indian tribe validition status to outstanding and to pending for the rest" do
          consumer.tribal_id = "345543345"
          consumer.coverage_purchased!
          consumer.verification_types.each { |verif|
            if verif.type_name == "American Indian Status"
              expect(verif.validation_status). to eq("outstanding")
            else
              expect(verif.validation_status).to eq("pending")
            end
          }
        end

      end
    end

    context "ssn_invalid" do
      it_behaves_like "IVL state machine transitions and workflow", "111111111", "us_citizen", true, "valid", :ssa_pending, :verification_outstanding, "ssn_invalid!"
      it_behaves_like "IVL state machine transitions and workflow", "111111111", "lawful_permanent_resident", true, "valid", :ssa_pending, :verification_outstanding, "ssn_invalid!"
      it_behaves_like "IVL state machine transitions and workflow", "111111111", "alien_lawfully_present", true, "valid", :ssa_pending, :verification_outstanding, "ssn_invalid!"
      it_behaves_like "IVL state machine transitions and workflow", "111111111", "naturalized_citizen", true, "valid", :ssa_pending, :verification_outstanding, "ssn_invalid!"
      it "fails ssn with callback" do
        consumer.aasm_state = "ssa_pending"
        consumer.ssn_invalid! verification_attr
        expect(verification_types.by_name("Social Security Number").first.validation_status).to eq("outstanding")
      end
      it "fails lawful presence with callback" do
        consumer.aasm_state = "ssa_pending"
        consumer.ssn_invalid! verification_attr
        expect(consumer.lawful_presence_determination.aasm_state).to eq("verification_outstanding")
      end
    end

    context "ssn_valid_citizenship_invalid" do
      describe "citizen" do
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "us_citizen", true, "valid", :ssa_pending, :verification_outstanding, "ssn_valid_citizenship_invalid!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "us_citizen", false, "outstanding", :ssa_pending, :verification_outstanding, "ssn_valid_citizenship_invalid!"
      end
      describe "immigrant" do
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "naturalized_citizen", true, "valid", :ssa_pending, :dhs_pending, "ssn_valid_citizenship_invalid!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "lawful_permanent_resident", true, "valid", :ssa_pending, :dhs_pending, "ssn_valid_citizenship_invalid!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "alien_lawfully_present", true, "valid", :ssa_pending, :dhs_pending, "ssn_valid_citizenship_invalid!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "naturalized_citizen", false, "outstanding", :ssa_pending, :dhs_pending, "ssn_valid_citizenship_invalid!"
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "alien_lawfully_present", false, "outstanding", :ssa_pending, :dhs_pending, "ssn_valid_citizenship_invalid!"
      end

      it "updates ssn validation with callback" do
        consumer.aasm_state = "ssa_pending"
        consumer.ssn_valid_citizenship_invalid! verification_attr
        expect(verification_types.by_name("Social Security Number").first.validation_status).to eq("verified")
      end

      it "fails lawful presence with callback" do
        consumer.aasm_state = "ssa_pending"
        consumer.ssn_valid_citizenship_invalid! verification_attr
        expect(consumer.lawful_presence_determination.aasm_state).to eq("verification_outstanding")
      end

      it "doesn't change user's citizen input" do
        consumer.aasm_state = "ssa_pending"
        consumer.citizen_status = "alien_lawfully_present"
        consumer.ssn_valid_citizenship_invalid! verification_attr
        expect(consumer.lawful_presence_determination.citizen_status).to eq("alien_lawfully_present")
        expect(consumer.lawful_presence_determination.citizenship_result).to eq("not_lawfully_present_in_us")
      end
    end

    context "ssn_valid_citizenship_valid" do
      before :each do
        consumer.lawful_presence_determination.deny! verification_attr
        consumer.citizen_status = "alien_lawfully_present"
      end
      [false, nil, true].each do |residency|
        if residency
          residency_status = "valid"
          to_state = :fully_verified
        elsif residency.nil?
          residency_status = "pending"
          to_state = :sci_verified
        else
          residency_status = "outstanding"
          to_state = :verification_outstanding
        end
        describe "residency #{residency} #{'pending' if residency.nil?}" do
          [:unverified, :ssa_pending, :verification_outstanding].each do |from_state|
            it_behaves_like "IVL state machine transitions and workflow", "111111111", "naturalized_citizen", residency, residency_status, from_state, to_state, "ssn_valid_citizenship_valid!"
            it "updates ssn citizenship with callback and doesn't change consumer citizen input" do
              consumer.ssn_valid_citizenship_valid! verification_attr
              expect(verification_types.by_name("Social Security Number").first.validation_status).to eq("verified")
              expect(consumer.lawful_presence_determination.verification_successful?).to eq true
              expect(consumer.lawful_presence_determination.citizen_status).to eq "alien_lawfully_present"
            end
          end
        end
      end
    end

    context "fail_dhs" do
      it_behaves_like "IVL state machine transitions and workflow", "111111111", "lawful_permanent_resident", true, "valid", :dhs_pending, :verification_outstanding, "fail_dhs!"
      it_behaves_like "IVL state machine transitions and workflow", "111111111", "alien_lawfully_present", false, "outstanding", :dhs_pending, :verification_outstanding, "fail_dhs!"
      it_behaves_like "IVL state machine transitions and workflow", "111111111", "naturalized_citizen", true,"valid", :dhs_pending, :verification_outstanding, "fail_dhs!"

      it "fails lawful presence with callback" do
        consumer.aasm_state = "dhs_pending"
        consumer.fail_dhs! verification_attr
        expect(consumer.lawful_presence_determination.aasm_state).to eq("verification_outstanding")
      end
    end

    context "pass_dhs" do
      before :each do
        consumer.lawful_presence_determination.deny! verification_attr
        consumer.citizen_status = "alien_lawfully_present"
      end
      [false, nil, true].each do |residency|
        if residency
          residency_status = "valid"
          to_state = :fully_verified
        elsif residency.nil?
          residency_status = "pending"
          to_state = :sci_verified
        else
          residency_status = "outstanding"
          to_state = :verification_outstanding
        end
        describe "residency #{residency} #{'pending' if residency.nil?}" do
          [:unverified, :dhs_pending, :verification_outstanding].each do |from_state|
            it_behaves_like "IVL state machine transitions and workflow", nil, "naturalized_citizen", residency, residency_status, from_state, to_state, "pass_dhs!"
            it_behaves_like "IVL state machine transitions and workflow", "111111111", "alien_lawfully_present", residency,residency_status, from_state, to_state, "pass_dhs!"
            it "updates citizenship with callback and doesn't change consumer citizen input" do
              consumer.pass_dhs! verification_attr
              expect(consumer.lawful_presence_determination.verification_successful?).to eq true
              expect(consumer.lawful_presence_determination.citizen_status).to eq "alien_lawfully_present"
            end
          end
        end
      end
    end

    context "pass_residency" do
      [nil, "111111111"].each do |ssn|
        it_behaves_like "IVL state machine transitions and workflow", ssn, "us_citizen", true, "valid", :unverified, :verification_outstanding, "fail_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "lawful_permanent_resident", true, "valid", :ssa_pending, :ssa_pending, "fail_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "alien_lawfully_present", true, "valid",  :dhs_pending, :dhs_pending, "fail_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "naturalized_citizen", false, "outstanding", :sci_verified, :verification_outstanding, "fail_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "alien_lawfully_present", false, "outstanding", :verification_outstanding, :verification_outstanding, "fail_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "alien_lawfully_present", false, "outstanding", :fully_verified, :verification_outstanding, "fail_residency!"
        it "updates residency status with callback" do
          consumer.is_state_resident = true
          consumer.fail_residency!
          expect(consumer.is_state_resident).to be false
        end
      end
    end

    context "fail_residency" do
      [nil, "111111111"].each do |ssn|
        it_behaves_like "IVL state machine transitions and workflow", ssn, "us_citizen", true, "valid", :unverified, :verification_outstanding, "fail_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "lawful_permanent_resident", true, "valid", :ssa_pending, :ssa_pending, "fail_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "alien_lawfully_present", true, "valid", :dhs_pending, :dhs_pending, "fail_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "naturalized_citizen", false, "outstanding", :sci_verified, :verification_outstanding, "fail_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "alien_lawfully_present", false, "outstanding", :verification_outstanding, :verification_outstanding, "fail_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "alien_lawfully_present", false, "outstanding", :fully_verified, :verification_outstanding, "fail_residency!"
        it "updates residency status with callback" do
          consumer.is_state_resident = true
          consumer.fail_residency! verification_attr
          expect(consumer.is_state_resident).to be false
        end
      end
    end

    context "trigger_residency" do
      [nil, "111111111"].each do |ssn|
        it_behaves_like "IVL state machine transitions and workflow", ssn, "lawful_permanent_resident", true, "valid", :ssa_pending, :ssa_pending, "trigger_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "alien_lawfully_present", true, "valid", :dhs_pending, :dhs_pending, "trigger_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "naturalized_citizen", false, "outstanding", :sci_verified, :sci_verified, "trigger_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "alien_lawfully_present", false, "outstanding", :verification_outstanding, :verification_outstanding, "trigger_residency!"
        it_behaves_like "IVL state machine transitions and workflow", ssn, "alien_lawfully_present", false, "outstanding", :fully_verified, :sci_verified, "trigger_residency!"
        it "updates residency status with callback" do
          if consumer.may_trigger_residency?
            consumer.is_state_resident = true
            consumer.trigger_residency!
            expect(consumer.is_state_resident).to be nil
          end
        end
      end
    end

    context "revert" do
      before :each do
        consumer.import! verification_attr
      end

      all_states.each do |state|
        it_behaves_like "IVL state machine transitions and workflow", "111111111", "us_citizen", true, "valid", state, :unverified, "revert!"
        it "updates ssn" do
          consumer.revert!
          expect(consumer.ssn_validation).to eq "pending"
        end

        it "updates lawful presence status" do
          consumer.revert!
          expect(consumer.lawful_presence_determination.verification_pending?).to eq true
        end
        it "updates residency status" do
          consumer.revert!
          expect(consumer.is_state_resident?).to eq true
        end
      end
    end

    context 'coverage_purchased_no_residency' do
      it_behaves_like 'IVL state machine transitions and workflow', '111111111', 'us_citizen', false, "outstanding", :unverified, :ssa_pending, 'coverage_purchased_no_residency!'
      it_behaves_like 'IVL state machine transitions and workflow', '111111111', 'naturalized_citizen', false, "outstanding", :unverified, :ssa_pending, 'coverage_purchased_no_residency!'
      it_behaves_like 'IVL state machine transitions and workflow', nil, 'alien_lawfully_present', true, "valid", :unverified, :dhs_pending, 'coverage_purchased_no_residency!'
      it_behaves_like 'IVL state machine transitions and workflow', nil, 'alien_lawfully_present', false, "outstanding", :unverified, :dhs_pending, 'coverage_purchased_no_residency!'
    end
  end

  describe "verification types" do
    let(:person) {FactoryGirl.create(:person, :with_consumer_role) }
    let(:consumer) { person.consumer_role }

    shared_examples_for "collecting verification types for person" do |v_types, types_count, ssn, citizen, native, age|
      before do
        person.ssn = nil unless ssn
        person.us_citizen = citizen
        person.dob = TimeKeeper.date_of_record - age.to_i.years
        person.tribal_id = "444444444" if native
        person.citizen_status = "indian_tribe_member" if native
        person.consumer_role.save
      end
      it "returns array of verification types" do
        expect(person.verification_types).to be_a Array
      end

      it "returns #{types_count} verification types" do
        expect(consumer.verification_types.count).to eq types_count
      end

      it "contains #{v_types} verification types" do
        expect(consumer.verification_types.map(&:type_name)).to eq v_types
      end
    end

    context "SSN + Citizen" do
      it_behaves_like "collecting verification types for person", ["DC Residency", "Social Security Number", "Citizenship"], 3, "2222222222", true, nil, 25
    end

    context "SSN + Immigrant" do
      it_behaves_like "collecting verification types for person", ["DC Residency", "Social Security Number", "Immigration status"], 3, "2222222222", false, nil, 20
    end

    context "SSN + Native Citizen" do
      it_behaves_like "collecting verification types for person", ["DC Residency", "Social Security Number", "Citizenship", "American Indian Status"], 4, "2222222222", true, "native", 20
    end

    context "Citizen with NO SSN" do
      it_behaves_like "collecting verification types for person", ["DC Residency", "Citizenship"], 2, nil, true, nil, 20
    end

    context "Immigrant with NO SSN" do
      it_behaves_like "collecting verification types for person", ["DC Residency", "Immigration status"], 2, nil, false, nil, 20
    end

    context "Native Citizen with NO SSN" do
      it_behaves_like "collecting verification types for person", ["DC Residency", "Citizenship", "American Indian Status"], 3, nil, true, "native", 20
    end
  end

  describe "#check_for_critical_changes" do
    sensitive_fields = ConsumerRole::VERIFICATION_SENSITIVE_ATTR
    all_fields = FactoryGirl.build(:person, :encrypted_ssn => "111111111", :gender => "male", "updated_by_id": "any").attributes.keys
    mask_hash = all_fields.map{|v| [v, (sensitive_fields.include?(v) ? "call" : "don't call")]}.to_h
    subject { ConsumerRole.new(:person => person) }
    let(:family) { double("Family", :person_has_an_active_enrollment? => true)}
    shared_examples_for "reping the hub fo critical changes" do |field, call, params|
      it "#{call} the hub if #{field} record was changed" do
        allow(Person).to receive(:person_has_an_active_enrollment?).and_return true
        allow(subject.person).to receive(:is_consumer_role_active?).and_return false
        if call == "call"
          expect(subject).to receive(:redetermine_verification!)
        else
          expect(subject).to_not receive(:redetermine_verification!)
        end
        subject.check_for_critical_changes(family, info_changed: subject.sensitive_information_changed?(params))
      end
    end
    mask_hash.each do |field, action|
      value = field == "dob" ? "2016-08-08" : "new filed record"
      it_behaves_like "reping the hub fo critical changes", field, action, {field => value}
    end
  end
end

describe "#revert_lawful_presence" do
  let(:person) { FactoryGirl.create(:person, :with_consumer_role) }
  let(:consumer) { person.consumer_role }
  let(:verification_types) { consumer.verification_types }
  let(:verification_attr) { OpenStruct.new({ :determined_at => Time.now, :vlp_authority => "hbx" })}

  it "should move Citizenship verification type to pending state" do
    consumer.lawful_presence_determination.authorize!(verification_attr)
    consumer.revert_lawful_presence(verification_attr)
    expect(consumer.lawful_presence_determination.aasm_state). to eq "verification_pending"
    expect(consumer.verification_types.by_name("DC Residency").first.validation_status). to eq "unverified"
    expect(consumer.verification_types.by_name("Social Security Number").first.validation_status). to eq "unverified"
    expect(consumer.verification_types.by_name("Citizenship").first.validation_status). to eq "pending"
  end
end

describe "it should check the residency status" do
  let(:person) { FactoryGirl.create(:person, :with_consumer_role, :with_active_consumer_role)}
  let(:consumer) { person.consumer_role }
  let(:verification_attr) { OpenStruct.new({ :determined_at => Time.now, :vlp_authority => "hbx" })}
  let!(:family) { FactoryGirl.create(:family, :with_primary_family_member_and_dependent, person: person) }
  let!(:hbx_enrollment) { FactoryGirl.create(:hbx_enrollment, household: family.active_household, aasm_state: "coverage_selected", kind: 'individual') }
  let!(:hbx_enrollment_member) { FactoryGirl.create(:hbx_enrollment_member, applicant_id: family.primary_applicant.id, eligibility_date: (TimeKeeper.date_of_record - 10.days), hbx_enrollment: hbx_enrollment) }
  let!(:enrollment) {consumer.person.primary_family.active_household.hbx_enrollments.first}
  context "consumer role should check for eligibility" do
    it "should move the enrollment to unverified" do
      consumer.coverage_purchased!
      expect(consumer.aasm_state).to eq("ssa_pending")
      enrollment.reload
      expect(enrollment.aasm_state).to eq("unverified")
    end

    it "should update the consumer and enrollment state when ssn and citizenship is valid" do
      consumer.coverage_purchased!
      consumer.ssn_valid_citizenship_valid!(verification_attr)
      expect(consumer.aasm_state).to eq("sci_verified")
      enrollment.reload
      expect(enrollment.aasm_state).to eq("unverified")
    end

    it "should set is_any_enrollment_member_outstanding to true when received negative response from residency hub" do
      consumer.coverage_purchased!
      consumer.ssn_valid_citizenship_valid!(verification_attr)
      consumer.fail_residency!
      expect(consumer.aasm_state).to eq("verification_outstanding")
      enrollment.reload
      expect(enrollment.aasm_state).to eq("coverage_selected")
      expect(enrollment.is_any_enrollment_member_outstanding).to eq(true)
    end

    it "should move the enrollment status to contingent when received negative response from residency hub" do
      consumer.coverage_purchased!
      consumer.ssn_valid_citizenship_valid!(verification_attr)
      consumer.pass_residency!
      expect(consumer.aasm_state).to eq("fully_verified")
      enrollment.reload
      expect(enrollment.aasm_state).to eq("coverage_selected")
    end
  end
end

describe "#find_document" do
  let(:consumer_role) {ConsumerRole.new}
  context "consumer role does not have any vlp_documents" do
    it "it creates and returns an empty document of given subject" do
      doc = consumer_role.find_document("Certificate of Citizenship")
      expect(doc).to be_a_kind_of(VlpDocument)
      expect(doc.subject).to eq("Certificate of Citizenship")
    end
  end

  context "consumer role has a vlp_document" do
    it "it returns the document" do
      document = consumer_role.vlp_documents.build({subject: "Certificate of Citizenship"})
      found_document = consumer_role.find_document("Certificate of Citizenship")
      expect(found_document).to be_a_kind_of(VlpDocument)
      expect(found_document).to eq(document)
      expect(found_document.subject).to eq("Certificate of Citizenship")
    end
  end
end

describe "Indian tribe member" do
  let(:person) { FactoryGirl.create(:person, :with_consumer_role) }
  let(:consumer_role) { person.consumer_role }
  let(:verification_types) { consumer.verification_types }
  let(:verification_attr) { OpenStruct.new({ :determined_at => Time.now, :vlp_authority => "hbx" })}

  context 'Responses from local hub and ssa hub'do

    it 'aasm state should be in verification outstanding if dc response is valid and consumer is tribe member' do
      person.update_attributes!(tribal_id: "12345")
      consumer_role.coverage_purchased!(verification_attr)
      consumer_role.pass_residency!
      consumer_role.ssn_valid_citizenship_valid!(verification_attr)
      expect(consumer_role.aasm_state). to eq 'verification_outstanding'
    end

    it 'aasm state should be in fully verified if dc response is valid and consumer is not a tribe member' do
      consumer_role.fail_residency!
      consumer_role.ssn_valid_citizenship_valid!(verification_attr)
      expect(consumer_role.aasm_state). to eq 'verification_outstanding'
    end

    it 'aasm state should be in verification_outstanding if dc response is negative and consumer is not a tribe member' do
      consumer_role.fail_residency!
      consumer_role.ssn_valid_citizenship_valid!(verification_attr)
      expect(consumer_role.aasm_state). to eq 'verification_outstanding'
    end

    it 'aasm state should be in fully verified if dc response is positive and consumer is not a tribe member' do
      consumer_role.update_attributes(is_state_resident: nil)
      consumer_role.ssn_valid_citizenship_valid!(verification_attr)
      consumer_role.pass_residency!
      expect(consumer_role.aasm_state). to eq 'fully_verified'
    end

    it 'aasm state should be in verification_outstanding if dc response is positive and consumer is a tribe member' do
      consumer_role.update_attributes(is_state_resident: nil)
      person.update_attributes!(tribal_id: "12345")
      consumer_role.ssn_valid_citizenship_valid!(verification_attr)
      consumer_role.pass_residency!
      expect(consumer_role.aasm_state). to eq 'verification_outstanding'
    end
  end

  context 'american indian verification type on coverage purchase' do
    it 'aasm state should be in verification outstanding and american indian status in outstanding upon coverage purchase' do
      person.update_attributes!(tribal_id: "12345")
      consumer_role.coverage_purchased!(verification_attr)
      american_indian_status = consumer_role.verification_types.by_name("American Indian Status").first
      expect(american_indian_status.validation_status). to eq 'outstanding'
      expect(consumer_role.aasm_state). to eq 'verification_outstanding'
    end
  end

  context 'admin verifies american indian status' do
    it 'consumer aasm state should be in fully_verified if all verification types are verified' do
      person.update_attributes!(tribal_id: "12345")
      consumer_role.coverage_purchased!(verification_attr)
      consumer_role.pass_residency!
      consumer_role.ssn_valid_citizenship_valid!(verification_attr)
      american_indian_status = consumer_role.verification_types.by_name("American Indian Status").first
      consumer_role.update_verification_type(american_indian_status, "admin verified")
      expect(consumer_role.aasm_state). to eq 'fully_verified'
      expect(american_indian_status.validation_status). to eq 'verified'
    end
  end

end

describe "#find_vlp_document_by_key" do
  let(:person) { FactoryGirl.create(:person, :with_consumer_role)}
  let(:consumer_role) { person.consumer_role }
  let(:key) {"sample-key"}
  let(:vlp_document) {VlpDocument.new({subject: "Certificate of Citizenship", identifier:"urn:openhbx:terms:v1:file_storage:s3:bucket:bucket_name##{key}"})}

  context "has a vlp_document without a file uploaded" do
    before do
      consumer_role.vlp_documents.build({subject: "Certificate of Citizenship"})
    end

    it "return no document" do
      found_document = consumer_role.find_vlp_document_by_key(key)
      expect(found_document).to be_nil
    end
  end

  context "has a vlp_document with a file uploaded" do
    before do
      consumer_role.verification_types.each{|type| type.vlp_documents << vlp_document }
    end

    it "returns vlp_document document" do
      found_document = consumer_role.find_vlp_document_by_key(key)
      expect(found_document).to eql(vlp_document)
    end
  end
end

describe "#build_nested_models_for_person" do
  let(:person) {FactoryGirl.create(:person)}
  let(:consumer_role) {ConsumerRole.new}

  before do
    allow(consumer_role).to receive(:person).and_return person
    consumer_role.build_nested_models_for_person
  end

  it "should get home and mailing address" do
    expect(person.addresses.map(&:kind)).to include "home"
    expect(person.addresses.map(&:kind)).to include 'mailing'
  end

  it "should get home and mobile phone" do
    expect(person.phones.map(&:kind)).to include "home"
    expect(person.phones.map(&:kind)).to include "mobile"
  end

  it "should get emails" do
    Email::KINDS.each do |kind|
      expect(person.emails.map(&:kind)).to include kind
    end
  end
end

describe "can_trigger_residency?" do
  let(:person) { FactoryGirl.create(:person, :with_consumer_role, :with_active_consumer_role)}
  let(:consumer_role) { person.consumer_role }
  let(:residency_verification_type) {consumer_role.verification_types.by_name("DC Residency").first}
  let(:family) { FactoryGirl.create(:family, :with_primary_family_member, person: person)}
  let(:enrollment) { double("HbxEnrollment", aasm_state: "coverage_selected")}
  let(:hub_request) {EventRequest.new}

  context "when person has age > 19 & has an active coverage" do

    before :each do
      allow(family).to receive(:person_has_an_active_enrollment?).and_return true
    end

    it "should return true if there is a change in address from non-dc to dc" do
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "false", dc_status: true)).to eq true
    end

    it "should return false if there is a change in address from dc to non-dc" do
      consumer_role.verification_types.by_name("DC Residency").first.update_attributes(validation_status: "verified")
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "true", dc_status: false)).to eq false
    end

    it "should return false if there is a change in address from dc to dc" do
      consumer_role.verification_types.by_name("DC Residency").first.update_attributes(validation_status: "verified")
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "false", dc_status: false)).to eq false
    end

    it "should return false if there is a change in address from non-dc to non-dc" do
      consumer_role.verification_types.by_name("DC Residency").first.update_attributes(validation_status: "verified")
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "true", dc_status: true)).to eq false
    end
  end

  context "when has an active coverage & address change from non-dc to dc", dbclean: :after_each do

    before do
      allow(family).to receive(:person_has_an_active_enrollment?).and_return true
    end

    it "should return true if age > 18" do
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "false", dc_status: true)).to eq true
    end

    it "should return false if age = 18" do
      person.update_attributes(dob: TimeKeeper.date_of_record - 18.years)
      consumer_role.verification_types.by_name("DC Residency").first.update_attributes(validation_status: "verified")
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "false", dc_status: true)).to eq false
    end

    it "should return false if age < 18" do
      consumer_role.person.update_attributes(dob: TimeKeeper.date_of_record - 15.years)
      consumer_role.verification_types.by_name("DC Residency").first.update_attributes(validation_status: "verified")
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "false", dc_status: true)).to eq false
    end
  end

  context "when age > 18 & address change from non-dc to dc" do
    before do
      allow(family).to receive_message_chain(:active_household, :hbx_enrollments, :where).and_return [enrollment]
    end

    it "should return true if has an active coverage" do
      allow(enrollment).to receive_message_chain(:hbx_enrollment_members, :family_member, :person).and_return [consumer_role.person]
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "false", dc_status: true)).to eq true
    end

    it "should return false if no active coverage" do
      consumer_role.verification_types.by_name("DC Residency").first.update_attributes(validation_status: "verified")
      allow(enrollment).to receive_message_chain(:hbx_enrollment_members, :family_member, :person).and_return [nil]
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "false", dc_status: true)).to eq false
    end
  end

  context "when age > 18 & address change from non-dc to dc & residency status" do
    before do
      allow(family).to receive_message_chain(:active_household, :hbx_enrollments, :where).and_return [enrollment]
    end

    it "should return true if residency status is unverified" do
      allow(enrollment).to receive_message_chain(:hbx_enrollment_members, :family_member, :person).and_return [consumer_role.person]
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "true", dc_status: true)).to eq true
    end

    it "should return false if residency status is not unverified" do
      consumer_role.verification_types.by_name("DC Residency").first.update_attributes(validation_status: "outstanding")
      allow(enrollment).to receive_message_chain(:hbx_enrollment_members, :family_member, :person).and_return [nil]
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "false", dc_status: true)).to eq false
    end

    it "should return true if residency status is not unverified & address change from non-dc to dc" do
      consumer_role.verification_types.by_name("DC Residency").first.update_attributes(validation_status: "outstanding")
      allow(enrollment).to receive_message_chain(:hbx_enrollment_members, :family_member, :person).and_return [consumer_role.person]
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "false", dc_status: true)).to eq true
    end

    it "should return false if residency status is not unverified & address change from non-dc to non-dc" do
      consumer_role.verification_types.by_name("DC Residency").first.update_attributes(validation_status: "outstanding")
      allow(enrollment).to receive_message_chain(:hbx_enrollment_members, :family_member, :person).and_return [consumer_role.person]
      expect(consumer_role.can_trigger_residency?(family, no_dc_address: "true", dc_status: true)).to eq false
    end
  end
end

RSpec.shared_examples "a consumer role unchanged by ivl_coverage_selected" do |c_state|
  let(:current_state) { c_state }

  describe "in #{c_state} status" do
    it "does not invoke coverage_selected!" do
      expect(subject).not_to receive(:coverage_purchased!)
      subject.ivl_coverage_selected
    end
  end
end

describe ConsumerRole, "receiving a notification of ivl_coverage_selected" do
  let(:person) {Person.new}
  subject { ConsumerRole.new(:aasm_state => current_state, :person => person) }
  describe "in unverified status" do
    let(:current_state) { "unverified" }
    it "fires coverage_selected!" do
      expect(subject).to receive(:coverage_purchased!)
      subject.ivl_coverage_selected
    end
  end

  it_behaves_like "a consumer role unchanged by ivl_coverage_selected", :ssa_pending
  it_behaves_like "a consumer role unchanged by ivl_coverage_selected", :dhs_pending
  it_behaves_like "a consumer role unchanged by ivl_coverage_selected", :verification_outstanding
  it_behaves_like "a consumer role unchanged by ivl_coverage_selected", :fully_verified
  it_behaves_like "a consumer role unchanged by ivl_coverage_selected", :verification_period_ended
end

describe "#add_type_history_element" do
  let(:person) {FactoryGirl.create(:person, :with_consumer_role)}
  let(:attr) { {verification_type: "verification_type",
                action: "action",
                modifier: "actor",
                update_reason: "reason"} }

  it "creates verification history record" do
    person.consumer_role.verification_type_history_elements.delete_all
    person.consumer_role.add_type_history_element(attr)
    expect(person.consumer_role.verification_type_history_elements.size).to be > 0
  end
end

describe 'coverage_purchased!' do
  let(:person) {FactoryGirl.create(:person, :with_consumer_role)}
  let(:consumer) {person.consumer_role}
  let(:verification_attr) { OpenStruct.new({ :determined_at => Time.now, :vlp_authority => "hbx" })}
  let(:start_date) { person.consumer_role.requested_coverage_start_date}


  it "should trigger call to ssa hub" do
    expect_any_instance_of(LawfulPresenceDetermination).to receive(:notify).with("local.enroll.lawful_presence.ssa_verification_request", {:person => person})
    person.consumer_role.coverage_purchased!
  end

  it "should trigger call to dhs hub if person is non native and no ssn " do
    person.update_attributes(ssn: nil)
    person.consumer_role.lawful_presence_determination.update_attributes(citizen_status: nil)
    expect_any_instance_of(LawfulPresenceDetermination).to receive(:notify).with("local.enroll.lawful_presence.vlp_verification_request", {:person => person, :coverage_start_date => start_date})
    person.consumer_role.coverage_purchased!
  end
end

describe "Verification Tracker" do
  let(:person) {FactoryGirl.create(:person, :with_consumer_role)}
  context "mongoid history" do
    it "stores new record with changes" do
      history_tracker_init =  HistoryTracker.count
      person.update_attributes(:first_name => "updated")
      expect(HistoryTracker.count).to be > history_tracker_init
    end
  end

  context "mongoid history extension" do
    it "stores action history element" do
      history_action_tracker_init =  person.consumer_role.history_action_trackers.count
      person.update_attributes(:first_name => "first_name updated", :last_name => "last_name updated")
      person.reload
      expect(person.consumer_role.history_action_trackers.count).to be > history_action_tracker_init
    end

    it "associates history element with mongoid history record" do
      person.update_attributes(:first_name => "first_name updated", :last_name => "last_name updated")
      person.reload
      expect(person.consumer_role.history_action_trackers.last.tracking_record).to be_a(HistoryTracker)
    end
  end
end