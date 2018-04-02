class VerificationType
  include Mongoid::Document
  include Mongoid::Timestamps

  embedded_in :person

  VALIDATION_STATES = %w(na pending processing review outstanding verified valid attested)

  field :type_name, type: String
  field :validation_status, type: String
  field :applied_roles, type: Array, default: ["consumer_role"] #[consumer_role, resident_role, ...]
  field :update_reason, type: String
  field :rejected, type: Boolean
  field :external_service, type: String
  field :due_date, type: Date
  field :due_date_type, type: String # admin, notice
  field :updated_by
  field :inactive, type: Boolean #use this field (assign true) only if type was present but for some reason if is not applicable anymore

  scope :active, -> { where(:inactive.ne => true ) }
  scope :by_name, ->(type_name) { where(:type_name => type_name) }

  # embeds_many :external_service_responses  -> needs datamigration
  embeds_many :type_history_elements


  embeds_many :vlp_documents, as: :documentable do
    def uploaded
      @target.select{|document| document.identifier }
    end
  end


  def type_unverified?
    !type_verified?
  end

  def type_verified?
    ["verified", "attested", "valid"].include? validation_status
  end

  def is_type_outstanding?
    type_unverified? && vlp_documents.empty?
  end

  def add_type_history_element(params)
    type_history_elements<<TypeHistoryElement.new(params)
  end

  def verif_due_date
    due_date || TimeKeeper.date_of_record
  end
end