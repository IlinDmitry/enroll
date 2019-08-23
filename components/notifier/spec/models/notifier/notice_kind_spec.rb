require 'rails_helper'

class DummyEmployerProfile
end

module Notifier
  RSpec.describe NoticeKind, type: :model, dbclean: :around_each do
    describe '.set_data_elements' do
      subject { Notifier::NoticeKind.new }

      let!(:template) { subject.build_template }

      before do
        allow(subject).to receive(:tokens).and_return([
          "employer_profile.account_number", "employer_profile.invoice_number", "employer_profile.invoice_date", "employer_profile.coverage_month", "employer_profile.total_amount_due", "employer_profile.date_due",
          "employer_profile.first_name", "employer_profile.last_name", "address.street_1", "address.street_2", "address.city", "address.state", "address.zip", "site_short_name", "site_invoice_bill_url",
          "contact_center_mailing_address_name", "contact_center_address_one", "contact_center_city", "contact_center_state", "contact_center_postal_code", "contact_center_tty_number", "employer_profile.first_name",
          "employer_profile.last_name", "employer_profile.coverage_month", "offered_product.plan_name", "offered_product.covered_subscribers", "offered_product.covered_dependents", "offered_product.total_charges",
          "employer_profile.total_amount_due", "enrollment.subscriber.last_name", "enrollment.subscriber.first_name", "enrollment.number_of_enrolled", "enrollment.employer_cost", "enrollment.employee_cost",
          "enrollment.premium"
        ])
        allow(subject).to receive(:conditional_tokens).and_return(["employer_profile.addresses.each do | address |", "employer_profile.offered_products.each do | offered_product |", "offered_product.enrollments.each do | enrollment |"])
      end

      it "should parse data elements for the template" do
        subject.set_data_elements
        expect(template.data_elements).to be_present
        expect(template.data_elements).to eq([
          "employer_profile.account_number", "employer_profile.invoice_number", "employer_profile.invoice_date", "employer_profile.coverage_month", "employer_profile.total_amount_due", "employer_profile.date_due",
          "employer_profile.first_name", "employer_profile.last_name", "site_short_name", "site_invoice_bill_url", "contact_center_mailing_address_name", "contact_center_address_one", "contact_center_city",
          "contact_center_state", "contact_center_postal_code", "contact_center_tty_number", "employer_profile.first_name", "employer_profile.last_name", "employer_profile.coverage_month",
          "employer_profile.total_amount_due", "employer_profile.addresses", "employer_profile.offered_products", "offered_product.enrollments"
        ])
      end
    end

    describe '.execute_notice' do
      let(:hbx_id) { "1234" }
      let(:resource) { EmployeeRole.new }
      let(:event_name) {"acapi.info.events.employer.welcome_notice_to_employer"}
      let(:payload) do
        {
          "employer_id" => hbx_id,
          "event_object_kind" => "DummyEmployerProfile",
          "event_object_id" => "12345"
        }
      end
      let(:resource) {double "resource"}

      let(:finder_mapping) do
        double "finder_mapping",
               mapped_class: double("mapped_class", search: resource),
               search_method: "search",
               identifier_key: "employer_id"
      end
      let(:subject) { Notifier::NoticeKind.new(event_name: event_name) }

      before do
        allow(Notifier::ApplicationEventMapper).to receive(:lookup_resource_mapping).and_return(finder_mapping)
        allow(subject).to receive(:generate_pdf_notice).and_return(true)
        allow(subject).to receive(:upload_and_send_secure_message).and_return(true)
        allow(subject).to receive(:send_generic_notice_alert).and_return(true)
        allow(subject).to receive(:send_generic_notice_alert_to_broker_and_ga).and_return(true)
        allow(subject).to receive(:store_paper_notice).and_return(true)
        subject.execute_notice(event_name, payload)
      end

      it "should receive send_generic_notice_alert" do
        expect(subject).to have_received(:send_generic_notice_alert)
      end

      it "should receive store_paper_notice" do
        expect(subject).to have_received(:store_paper_notice)
      end
    end

    describe 'notice builder methods' do
      let(:notice_number) {"IVL_PRE"}
      let(:title) {"Update your information at DC Health Link by October 15"}
      let(:description) {"Notice to be sent out to individuals with AQHP(Assisted)/UQHP(Unassisted)"}
      let(:event_name) {"projected_eligibility_notice"}
      let(:market_kind) {"aca_individual"}
      let(:resource) {ConsumerRole.new}
      let(:recipient) {Notifier::MergeDataModels::ConsumerRole}
      let(:raw_body) {'TEST_RAW_BODY'}

      let(:subject) {Notifier::NoticeKind.new(notice_number: notice_number,
                                              title: title,
                                              description: description,
                                              event_name: event_name,
                                              market_kind: market_kind,
                                              resource: resource,
                                              recipient: recipient,
                                              template: {raw_body: raw_body})}

      before(:each) do
        subject.resource = resource
      end

      it "should have valid_resource" do
        expect(subject.has_valid_resource?).to eq(true)
      end

      it "should have not valid_resource" do
        subject.resource = nil
        expect(subject.has_valid_resource?).to eq(false)
      end

      it "should have sub_resource" do
        expect(subject.sub_resource?).to eq(true)
      end

      it "should have not sub_resource" do
        subject.resource = nil
        expect(subject.sub_resource?).to eq(false)
      end
    end


    describe '.generate_pdf_notice' do
      let(:notice_number) {"IVL_PRE"}
      let(:title) {"Update your information at DC Health Link by October 15"}
      let(:description) {"Notice to be sent out to individuals with AQHP(Assisted)/UQHP(Unassisted)"}
      let(:event_name) {"projected_eligibility_notice"}
      let(:market_kind) {"aca_individual"}
      let(:resource) {ConsumerRole.new}
      let(:recipient) {Notifier::MergeDataModels::ConsumerRole}
      let(:raw_body) {'TEST_RAW_BODY'}

      let(:subject) {Notifier::NoticeKind.new(notice_number: notice_number,
                                              title: title,
                                              description: description,
                                              event_name: event_name,
                                              market_kind: market_kind,

                                              recipient: recipient,
                                              template: {raw_body: raw_body})}
      let (:file) {"#{Rails.root}/tmp/#{subject.title.titleize.gsub(/\s+/, '_')}_#{subject.notice_recipient.hbx_id}.pdf"}

      before(:each) do
        subject.generate_pdf_notice
      end

      it "pdf file exists" do
        subject.generate_pdf_notice
        expect(File.exist?(file)).to eq(true)
      end

      it "pdf file have 9 pages" do
        page_analysis = PDF::Inspector::Page.analyze_file(file)
        expect(page_analysis.pages.size).to eq(9)
      end

      it "pdf file has text from raw body" do
        text_analysis = PDF::Inspector::Text.analyze_file(file)
        content_string = text_analysis.strings.join(" ")
        expect(content_string).to include(raw_body)
      end
    end
  end
end
