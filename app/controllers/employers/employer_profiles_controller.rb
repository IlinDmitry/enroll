class Employers::EmployerProfilesController < Employers::EmployersController

  include ApplicationHelper

  before_action :find_employer, only: [:show, :show_profile, :destroy, :inbox,
                                       :bulk_employee_upload, :bulk_employee_upload_form, :download_invoice, :show_invoice, :export_census_employees, :link_from_quote, :generate_checkbook_urls]
  before_action :check_show_permissions, only: [:show, :show_profile, :destroy, :inbox, :bulk_employee_upload, :bulk_employee_upload_form]
  before_action :check_index_permissions, only: [:index]
  before_action :check_employer_staff_role, only: [:new]
  before_action :check_access_to_organization, only: [:edit]
  before_action :check_and_download_invoice, only: [:download_invoice, :show_invoice]
  around_action :wrap_in_benefit_group_cache, only: [:show]
  skip_before_action :verify_authenticity_token, only: [:show], if: :check_origin?
  before_action :updateable?, only: [:create, :update]
  before_action :wells_fargo_sso, only: [:show]
  before_action :modify_admin_tabs?, only: %i[terminate_employee_roster_enrollments]
  layout "two_column", except: [:new]

  def link_from_quote
    claim_code = params[:claim_code].upcase
    import_roster = params[:import_roster] == "yes" ? true : false

    claim_code_status = Quote.claim_code_status?(claim_code)

    if claim_code_status == "invalid"
      flash[:error] = 'Quote claim code not found.'
    elsif claim_code_status == "claimed"
      flash[:error] = 'Quote claim code already claimed.'
    else
      if @employer_profile.build_plan_year_from_quote(claim_code, import_roster)
        flash[:notice] = 'Code claimed with success. Your Plan Year has been created.'
      else
        flash[:error] = 'There was issue claiming this quote.'
      end
    end

    redirect_to employers_employer_profile_path(@employer_profile, tab: 'benefits')
  end

  def index
    if params[:broker_agency_id].blank?
      @q = params.permit(:q)[:q]
      @orgs = Organization.search(@q).exists(employer_profile: true)
    else
      @orgs = Organization.by_broker_agency_profile(BSON::ObjectId.from_string(params[:broker_agency_id]))

    end

    if @q.blank?
      @page_alphabets = page_alphabets(@orgs, "legal_name")
      page_no = cur_page_no(@page_alphabets.first)
      @organizations = @orgs.where("legal_name" => /^#{page_no}/i)
      @employer_profiles = @organizations.map {|o| o.employer_profile}
    else
      @employer_profiles = @orgs.map {|o| o.employer_profile}
    end

    @profile = find_mailbox_provider
  end

  def welcome
  end

  def search
    @employer_profile = Forms::EmployerCandidate.new
    respond_to do |format|
      format.html
      format.js
    end
  end

  def match
    @employer_candidate = Forms::EmployerCandidate.new(params.require(:employer_profile))
    if @employer_candidate.valid?
      found_employer = @employer_candidate.match_employer
      unless params["create_employer"].present?
        if found_employer.present?
          @employer_profile = found_employer
          respond_to do |format|
            format.js { render 'match' }
            format.html { render 'match' }
          end
        else
          respond_to do |format|
            format.js { render 'no_match' }
            format.html { render 'no_match' }
          end
        end
      else
        params.permit!
        build_organization
        @employer_profile.attributes = params[:employer_profile]
        @organization.save(validate: false)
        build_office_location
        respond_to do |format|
          format.js { render "edit" }
          format.html { render "edit" }
        end
      end
    else
      @employer_profile = @employer_candidate
      respond_to do |format|
        format.js { render 'search' }
        format.html { render 'search' }
      end
    end
  end

  def my_account
  end

  def show
    @tab = params['tab']
    @broker_agency_profile_id = @employer_profile.active_broker_agency_account.broker_agency_profile_id if @employer_profile.active_broker_agency_account.present?
    if params[:q] || params[:page] || params[:commit] || params[:status]
      paginate_employees
    else
      case @tab
      when 'benefits'
        @current_plan_year = @employer_profile.renewing_plan_year || @employer_profile.active_plan_year
        sort_plan_years(@employer_profile.plan_years)
      when 'documents'
      when 'accounts'
        collect_and_sort_invoices(params[:sort_order])
        @employer_profile_account = @employer_profile.employer_profile_account
        @sort_order = params[:sort_order].nil? || params[:sort_order] == "ASC" ? "DESC" : "ASC"
        #only exists if coming from redirect from sso failing
        @page_num = params[:page_num] if params[:page_num].present?
        if @page_num.present?
          retrieve_payments_for_page(@page_num)
        else
          retrieve_payments_for_page(1)
        end
        respond_to do |format|
          format.js {render 'employers/employer_profiles/my_account/accounts/payment_history'}
          format.html
        end
      when 'employees'
        @current_plan_year = @employer_profile.show_plan_year
        paginate_employees
      when 'brokers'
        @broker_agency_accounts = @employer_profile.broker_agency_accounts
      when 'inbox'

      else
        @broker_agency_accounts = @employer_profile.broker_agency_accounts
        @current_plan_year = @employer_profile.show_plan_year
        collect_and_sort_invoices(params[:sort_order])
        @sort_order = params[:sort_order].nil? || params[:sort_order] == "ASC" ? "DESC" : "ASC"

        set_flash_by_announcement if @tab == 'home'
      end
    end
  end

  def show_profile
    @tab ||= params[:tab]
    @broker_agency_profile_id = @employer_profile.active_broker_agency_account.broker_agency_profile_id if @employer_profile.active_broker_agency_account.present?
    if @tab == 'benefits'
      @current_plan_year = @employer_profile.active_plan_year
      @plan_years = @employer_profile.plan_years.order(id: :desc)
    elsif @tab == 'employees'
      paginate_employees
    elsif @tab == 'families'
      #families defined as employee_roles.each { |ee| ee.person.primary_family }
      paginate_families
    elsif @tab == "inbox"
      @folder = params[:folder] || 'Inbox'
      @sent_box = false
      respond_to do |format|
        format.js { render 'employers/employer_profiles/inbox' }
      end
    end
  end

  def new
    @organization = Forms::EmployerProfile.new
  end

  def edit
    @organization = Organization.find(params[:id])
    @employer_profile = @organization.employer_profile
    @staff = Person.staff_for_employer_including_pending(@employer_profile)
    @add_staff = params[:add_staff]
    @plan_year = @employer_profile.plan_years.where(id: params[:plan_year_id]).first
  end

  def create

    params.permit!
    @organization = Forms::EmployerProfile.new(params[:organization])
    organization_saved = false
    begin
      organization_saved, pending = @organization.save(current_user, params[:employer_id])
    rescue Exception => e
      flash[:error] = e.message
      render action: "new"
      return
    end
    if organization_saved
      @person = current_user.person
      create_sso_account(current_user, current_user.person, 15, "employer") do
        if pending
          # flash[:notice] = 'Your Employer Staff application is pending'
          render action: 'show_pending'
        else
          redirect_to employers_employer_profile_path(@organization.employer_profile, tab: 'home')
        end
      end
    else
      render action: "new"
    end
  end

  def show_pending
  end

  def update
    sanitize_employer_profile_params
    params.permit!
    @organization = Organization.find(params[:id])

    #save duplicate office locations as json in case we need to refresh
    @organization_dup = @organization.office_locations.as_json
    @employer_profile = @organization.employer_profile
    @employer = @employer_profile.match_employer(current_user)
    if (current_user.has_employer_staff_role? && @employer_profile.staff_roles.include?(current_user.person)) || current_user.person.agent?
      @organization.assign_attributes(organization_profile_params)

      #clear office_locations, don't worry, we will recreate
      @organization.assign_attributes(:office_locations => [])
      @organization.save(validate: false)

      if @organization.update_attributes(employer_profile_params)
        @organization.notify_legal_name_or_fein_change
        @organization.notify_address_change(@organization_dup,employer_profile_params)
        flash[:notice] = 'Employer successfully Updated.'
        redirect_to edit_employers_employer_profile_path(@organization)
      else
        org_error_msg = @organization.errors.full_messages.join(",").humanize if @organization.errors.present?

        #in case there was an error, reload from saved json
        @organization.assign_attributes(:office_locations => @organization_dup)
        @organization.save(validate: false)
        #@organization.reload
        flash[:error] = "Employer information not saved. #{org_error_msg}."
        redirect_to edit_employers_employer_profile_path(@organization)
      end
    else
      flash[:error] = 'You do not have permissions to update the details'
      redirect_to edit_employers_employer_profile_path(@employer_profile)
    end
  end

  def inbox
    @folder = params[:folder] || 'Inbox'
    @sent_box = false
    respond_to do |format|
      format.js { render 'inbox' }
      format.html { render 'inbox' }
    end
  end

  def consumer_override
    session[:person_id] = params['person_id']
    redirect_to family_account_path(employer_profile_id: params['employer_profile_id'])
  end

  def export_census_employees
    respond_to do |format|
      format.csv { send_data @employer_profile.census_employees.sorted.to_csv, filename: "#{@employer_profile.legal_name.parameterize.underscore}_census_employees_#{TimeKeeper.date_of_record}.csv" }
    end
  end

  def bulk_employee_upload_form
  end


  def generate_checkbook_urls
    trigger_notice_observer(@employer_profile, @employer_profile, 'out_of_pocker_url_notifier')
    flash[:notice] = "Custom Plan Match instructions are being generated.  Check your secure Messages inbox shortly."
    redirect_to action: :show, :tab => :employees
  end

  def download_invoice
    options={}
    options[:content_type] = @invoice.type
    options[:filename] = @invoice.title
    send_data Aws::S3Storage.find(@invoice.identifier) , options
  end

  def show_invoice
    options={}
    options[:filename] = @invoice.title
    options[:type] = 'application/pdf'
    options[:disposition] = 'inline'
    send_data Aws::S3Storage.find(@invoice.identifier) , options
  end

  def bulk_employee_upload
    file = params.require(:file)
    @census_employee_import = CensusEmployeeImport.new({file:file, employer_profile:@employer_profile})
    begin
    if @census_employee_import.save
      redirect_to "/employers/employer_profiles/#{@employer_profile.id}?employer_profile_id=#{@employer_profile.id}&tab=employees", :notice=>"#{@census_employee_import.length} records uploaded from CSV"
    else
      render "employers/employer_profiles/employee_csv_upload_errors"
    end
    rescue Exception => e
      if e.message == "Unrecognized Employee Census spreadsheet format. Contact DC Health Link for current template."
        render "employers/employer_profiles/_download_new_template"
      else
        @census_employee_import.errors.add(:base, e.message)
        render "employers/employer_profiles/employee_csv_upload_errors"
      end
    end


  end

  def redirect_to_first_allowed
    redirect_to employers_employer_profile_path(:id => current_user.person.employer_staff_roles.first.employer_profile_id)
  end


  def terminate_employee_roster_enrollments
    employer_profile = EmployerProfile.find(params["employer_profile_id"])
    if employer_profile.active_plan_year.present?
      employer_profile.terminate_roster_enrollments(terminate_employee_roster_enrollments_params)
      flash[:notice] = "Successfully terminated employee enrollments."
    else
      flash[:error] = "No Active Plan Year present, unable to terminate employee enrollments."
    end

    redirect_to employers_employer_profile_path(employer_profile) + "?tab=employees"
  end

  private

  def wells_fargo_sso
    id_params = params.permit(:id, :employer_profile_id, :tab)
    id = id_params[:id] || id_params[:employer_profile_id]
    employer_profile = EmployerProfile.find(id)
    #grab url for WellsFargoSSO and store in insance variable
    email = (employer_profile.staff_roles.first && employer_profile.staff_roles.first.work_email_or_best) || nil

    if email.present?
      wells_fargo_sso = WellsFargo::BillPay::SingleSignOn.new(@employer_profile.hbx_id, @employer_profile.hbx_id, @employer_profile.dba.blank? ? @employer_profile.legal_name : @employer_profile.dba, email)
    end

    if wells_fargo_sso.present?
      if wells_fargo_sso.token.present?
        @wf_url = wells_fargo_sso.url
      end
    end
  end

  def retrieve_payments_for_page(page_no)
    if @payments = @employer_profile.premium_payments
      @payments = @payments.order_by(:paid_on => 'desc').skip((page_no.to_i - 1)*10).limit(10)
    end
  end

  def modify_admin_tabs?
    authorize EmployerProfile, :modify_admin_tabs?
  end

  def updateable?
    authorize EmployerProfile, :updateable?
  end

  def collect_and_sort_invoices(sort_order='ASC')
    @invoices = @employer_profile.organization.try(:invoices)
    @invoice_years = (Settings.aca.shop_market.employer_profiles.minimum_invoice_display_year..TimeKeeper.date_of_record.year).to_a.reverse
    if @invoices
      sort_order == 'ASC' ? @invoices.sort_by!(&:date) : @invoices.sort_by!(&:date).reverse!
    end
  end

  def check_and_download_invoice
    @invoice = @employer_profile.organization.invoices.select{ |inv| inv.id.to_s == params[:invoice_id]}.first
  end

  def sort_plan_years(plans)
    renewing_states = PlanYear::RENEWING_PUBLISHED_STATE + PlanYear::RENEWING
    renewing = plans.select { |plan_year| renewing_states.include? plan_year.aasm_state }
    ineligible_plans, active_plans = plans.partition { |plan_year| PlanYear::INELIGIBLE_FOR_EXPORT_STATES.include? plan_year.aasm_state }
    ineligible_plans = ineligible_plans.select { |plan_year| renewing.exclude? plan_year }
    active_plans = active_plans.partition { |plan_year| PlanYear::PUBLISHED.include? plan_year.aasm_state }.flatten
    active_plans = active_plans.select { |plan_year| renewing.exclude? plan_year }
    @plan_years = renewing + active_plans + ineligible_plans
  end

  def paginate_employees
    status_params = params.permit(:id, :status, :search)
    @status = status_params[:status] || 'active'
    @search = status_params[:search] || false
    #@available_employee_names ||= @employer_profile.census_employees.sorted.map(&:full_name).map(&:strip).map {|name| name.squeeze(" ")}.uniq
    #@available_employee_names ||= @employer_profile.census_employees.where(last_name: => /^#{page_no}/i).limit(20).map(&:full_name).map(&:strip).map {|name| name.squeeze(" ")}.uniq

    census_employees = case @status
                       when 'terminated'
                         @employer_profile.census_employees.terminated.sorted
                       when 'all'
                         @employer_profile.census_employees.sorted
                       when 'cobra'
                         @employer_profile.census_employees.by_cobra.sorted
                       else
                         @employer_profile.census_employees.active.sorted
                       end
    if params["employee_search"].present?
      query_string = CensusEmployee.search_hash(params["employee_search"])
      census_employees = census_employees.any_of(query_string)
    end
    @page_alphabets = page_alphabets(census_employees, "last_name")

    if params[:page].present?
      page_no = cur_page_no(@page_alphabets.first)
      @census_employees = census_employees.where("last_name" => /^#{page_no}/i).page(params[:pagina])
      #@available_employee_names ||= @census_employees.limit(20).map(&:full_name).map(&:strip).map {|name| name.squeeze(" ")}.uniq
    else
      @total_census_employees_quantity = census_employees.count
      @census_employees = census_employees.limit(20).to_a
      #@avaliable_employee_names ||= @census_employees.map(&:full_name).map(&:strip).map {|name| name.squeeze(" ")}.uniq
    end
  end

  def paginate_families
    #FIXME add paginate
    @employees = @employer_profile.employee_roles.select { |ee| CensusEmployee::EMPLOYMENT_ACTIVE_STATES.include?(ee.census_employee.aasm_state)}
  end

  def check_employer_staff_role
    if current_user.person && current_user.person.has_active_employer_staff_role?
      redirect_to employers_employer_profile_path(:id => current_user.person.active_employer_staff_roles.first.employer_profile_id, :tab => "home")
    end
  end

  def find_mailbox_provider
    hbx_staff = current_user.person.hbx_staff_role
    if hbx_staff
      profile = current_user.person.hbx_staff_role.hbx_profile
    else
      broker_id = current_user.person.broker_role.broker_agency_profile_id.to_s
      profile = BrokerAgencyProfile.find(broker_id)
    end
    return profile
  end

  def check_show_permissions
    id_params = params.permit(:id, :employer_profile_id)
    id = id_params[:id] || id_params[:employer_profile_id]
    ep = EmployerProfile.find(id)
    policy = ::AccessPolicies::EmployerProfile.new(current_user)
    policy.authorize_show(ep, self)
  end

  def check_index_permissions
    policy = ::AccessPolicies::EmployerProfile.new(current_user)
    policy.authorize_index(params[:broker_agency_id], self)
  end

  def check_admin_staff_role
    if current_user.has_hbx_staff_role? || current_user.has_broker_agency_staff_role? || current_user.has_broker_role?
    elsif current_user.has_employer_staff_role?
      ep_id = current_user.person.employer_staff_roles.first.employer_profile_id
      if ep_id.to_s != params[:id].to_s
        redirect_to employers_employer_profile_path(:id => current_user.person.employer_staff_roles.first.employer_profile_id)
      end
    else
      redirect_to new_employers_employer_profile_path
    end
  end

  def check_access_to_organization
    id = params.permit(:id)[:id]
    organization = Organization.find(id)
    policy = ::AccessPolicies::EmployerProfile.new(current_user)
    policy.authorize_edit(organization.employer_profile, self)
  end

  def find_employer
    id_params = params.permit(:id, :employer_profile_id, :tab)
    id = id_params[:id] || id_params[:employer_profile_id]
    @employer_profile = EmployerProfile.find(id)
    render file: 'public/404.html', status: 404 if @employer_profile.blank?
  end

  def organization_profile_params
    params.require(:organization).permit(
      :id,
      :employer_profile_attributes => [:legal_name, :entity_kind, :dba]
    )
  end

  def employer_profile_params
    params.require(:organization).permit(
      :employer_profile_attributes => [ :entity_kind, :contact_method, :dba, :legal_name],
      :office_locations_attributes => [
        {:address_attributes => [:kind, :address_1, :address_2, :city, :state, :zip]},
        {:phone_attributes => [:kind, :area_code, :number, :extension]},
        {:email_attributes => [:kind, :address]},
        :is_primary
      ]
    )
  end

  def sanitize_employer_profile_params
    params[:organization][:office_locations_attributes].each do |key, location|
      params[:organization][:office_locations_attributes].delete(key) unless location['address_attributes']
      location.delete('phone_attributes') if (location['phone_attributes'].present? && location['phone_attributes']['number'].blank?)
      office_locations = params[:organization][:office_locations_attributes]
      if office_locations && office_locations[key]
        params[:organization][:office_locations_attributes][key][:is_primary] = (office_locations[key][:address_attributes][:kind] == 'primary')
      end
    end
  end

  def build_organization
    @organization = Organization.new
    @employer_profile = @organization.build_employer_profile
  end

  def build_employer_profile_params
    build_organization
    build_office_location
  end

  def build_office_location
    @organization.office_locations.build unless @organization.office_locations.present?
    office_location = @organization.office_locations.first
    office_location.build_address unless office_location.address.present?
    office_location.build_phone unless office_location.phone.present?
    @organization
  end

  def wrap_in_benefit_group_cache
#    prof_result = RubyProf.profile do
      Caches::RequestScopedCache.allocate(:employer_calculation_cache_for_benefit_groups)
      yield
      Caches::RequestScopedCache.release(:employer_calculation_cache_for_benefit_groups)
#    end
#    printer = RubyProf::MultiPrinter.new(prof_result)
#    printer.print(:path => File.join(Rails.root, "rprof"), :profile => "profile")
  end

  def terminate_employee_roster_enrollments_params
    params.permit(:employer_profile_id, :termination_date, :termination_reason, :transmit_xml)
  end

  def employer_params
    params.permit(:first_name, :last_name, :dob)
  end

  def check_origin?
    request.referrer.present? and URI.parse(request.referrer).host == "app.dchealthlink.com"
  end

  def get_sic_codes
    @grouped_options = Caches::SicCodesCache.load
  end
end
