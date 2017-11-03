require File.join(Rails.root, "lib/mongoid_migration_task")

class TriggerBrokerInvitationUrl< MongoidMigrationTask
  def migrate
    npn = ENV['broker_npn']
    broker_role = BrokerRole.by_npn(npn).first if npn.present?
    if broker_role.nil?
      puts "No broker role found with npn: #{npn} " unless Rails.env.test?
    else
      broker_role.send_invitation
      puts "Invitation sent" unless Rails.env.test?
    end
  end
end
