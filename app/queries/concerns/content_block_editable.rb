module ContentBlockEditable
  include ActiveSupport::Concern

  def course
    target.level.course if target.present?
  end

  def target
    @target ||= begin
      if content_block.present?
        content_block.latest_version.target
      end
    end
  end

  def content_block
    @content_block ||= ContentBlock.find_by(id: id)
  end

  def json_attributes
    attributes = content_block.attributes
      .slice('id', 'block_type', 'content', 'sort_index')
      .with_indifferent_access

    if content_block.file.attached?
      attributes[:content].merge!(
        url: Rails.application.routes.url_helpers.rails_blob_path(content_block.file, only_path: true),
        filename: content_block.file.filename.to_s
      )
    end

    attributes
  end

  def target_version
    @target_version ||= target.current_target_version
  end

  def content_blocks
    @content_blocks ||= target_version.content_blocks
  end

  def must_be_latest_version
    return if content_blocks.where(id: id).present?

    errors[:base] << 'You cannot edit an older version'
  end
end