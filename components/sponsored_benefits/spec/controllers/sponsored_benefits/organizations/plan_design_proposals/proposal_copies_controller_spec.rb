require 'rails_helper'
require "#{SponsoredBenefits::Engine.root}/spec/shared_contexts/sponsored_benefits"

module SponsoredBenefits
  RSpec.describe Organizations::PlanDesignProposals::ProposalCopiesController, type: :controller, dbclean: :around_each  do
    routes { SponsoredBenefits::Engine.routes }
    include_context "set up broker agency profile for BQT, by using configuration settings"

    let!(:person) { FactoryGirl.create(:person, :with_broker_role) }
    let!(:user_with_broker_role) { FactoryGirl.create(:user, person: person) }

    describe "POST #create" do
      it "should return a success response" do
        person.broker_role.update_attributes(broker_agency_profile_id: plan_design_organization.owner_profile_id)
        sign_in user_with_broker_role
        post :create, plan_design_proposal_id: plan_design_proposal.id.to_s
        plan_design_census_employee
        expect(flash[:success]).to eq "Proposal successfully copied"
      end
    end
  end
end
