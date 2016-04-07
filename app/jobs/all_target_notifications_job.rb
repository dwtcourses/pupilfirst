class AllTargetNotificationsJob < ActiveJob::Base
  queue_as :default

  # ping with appropriate message to the appropriate target based on notification_type received
  # rubocop:disable Metrics/CyclomaticComplexity
  def perform(target, notification_type)
    return unless valid_notification_types.include? notification_type

    # copy arguments to instance variables for cleaner code
    @target = target
    @notification_type = notification_type

    case notification_type
      when 'new_target'
        notify_founders_on_slack message: @target.details_as_slack_message
      when 'revise_target'
        notify_founders_on_slack message: @target.revision_as_slack_message
      when 'mild_reminder'
        notify_founders_on_slack message: @target.mild_slack_reminder
      when 'strong_reminder'
        notify_founders_on_slack message: @target.strong_slack_reminder
      when 'batch_deploy'
        notify_batch_on_slack_channel
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def valid_notification_types
    %w(new_target revise_target mild_reminder strong_reminder batch_deploy)
  end

  def notify_founders_on_slack(message:)
    PublicSlackTalk.post_message message: message, founders: @target.slack_targets
  end

  def notify_batch_on_slack_channel
    channel = @target&.startup&.batch&.slack_channel
    return unless channel.present?

    PublicSlackTalk.post_message message: @target.batch_deploy_message, channel: channel
  end
end
