# encoding: utf-8
# frozen_string_literal: true

class Startup < ApplicationRecord
  include FriendlyId
  acts_as_taggable

  # For an explanation of these legacy values, see linked trello card.
  #
  # @see https://trello.com/c/SzqE6l8U
  LEGACY_STARTUPS_COUNT = 849
  LEGACY_INCUBATION_REQUESTS = 5281

  REGISTRATION_TYPE_PRIVATE_LIMITED = 'private_limited'
  REGISTRATION_TYPE_PARTNERSHIP = 'partnership'
  REGISTRATION_TYPE_LLP = 'llp' # Limited Liability Partnership

  MAX_PITCH_CHARACTERS = 140 unless defined?(MAX_PITCH_CHARACTERS)
  MAX_PRODUCT_DESCRIPTION_CHARACTERS = 150
  MAX_CATEGORY_COUNT = 3

  PRODUCT_PROGRESS_IDEA = 'idea'
  PRODUCT_PROGRESS_MOCKUP = 'mockup'
  PRODUCT_PROGRESS_PROTOTYPE = 'prototype'
  PRODUCT_PROGRESS_PRIVATE_BETA = 'private_beta'
  PRODUCT_PROGRESS_PUBLIC_BETA = 'public_beta'
  PRODUCT_PROGRESS_LAUNCHED = 'launched'

  SV_STATS_LINK = 'bit.ly/svstats2'

  # agreement duration in years
  AGREEMENT_DURATION = 5

  def self.valid_product_progress_values
    [
      PRODUCT_PROGRESS_IDEA, PRODUCT_PROGRESS_MOCKUP, PRODUCT_PROGRESS_PROTOTYPE, PRODUCT_PROGRESS_PRIVATE_BETA,
      PRODUCT_PROGRESS_PUBLIC_BETA, PRODUCT_PROGRESS_LAUNCHED
    ]
  end

  def self.valid_registration_types
    [REGISTRATION_TYPE_PRIVATE_LIMITED, REGISTRATION_TYPE_PARTNERSHIP, REGISTRATION_TYPE_LLP]
  end

  scope :batched, -> { where.not(batch_id: nil) }
  scope :approved, -> { where.not(dropped_out: true) }
  scope :dropped_out, -> { where(dropped_out: true) }
  scope :not_dropped_out, -> { where.not(dropped_out: true) }
  scope :agreement_signed, -> { where 'agreement_signed_at IS NOT NULL' }
  scope :agreement_live, -> { where('agreement_signed_at > ?', AGREEMENT_DURATION.years.ago) }
  scope :agreement_expired, -> { where('agreement_signed_at < ?', AGREEMENT_DURATION.years.ago) }
  scope :without_founders, -> { where.not(id: (Founder.pluck(:startup_id).uniq - [nil])) }
  scope :timeline_verified, -> { joins(:timeline_events).where(timeline_events: { verified_status: TimelineEvent::VERIFIED_STATUS_VERIFIED }).distinct }
  scope :batched_and_approved, -> { batched.approved }

  # Custom scope to allow AA to filter by intersection of tags.
  scope :ransack_tagged_with, ->(*tags) { tagged_with(tags) }

  def self.ransackable_scopes(_auth)
    %i(ransack_tagged_with)
  end

  # Returns the latest verified timeline event that has an image attached to it.
  #
  # Do not return private events!
  #
  # @return TimelineEvent
  def showcase_timeline_event
    timeline_events.verified.order('event_on DESC').detect do |timeline_event|
      !timeline_event.founder_event?
    end
  end

  # Returns startups that have accrued no karma points for last week (starting monday). If supplied a date, it
  # calculates for week bounded by that date.
  def self.inactive_for_week(date: 1.week.ago)
    date = date.in_time_zone('Asia/Calcutta')

    # First, find everyone who doesn't fit the criteria.
    startups_with_karma_ids = joins(:karma_points)
      .where(karma_points: { created_at: (date.beginning_of_week + 18.hours)..(date.end_of_week + 18.hours) })
      .pluck(:id)

    # Filter them out.
    batched.approved.not_dropped_out.where.not(id: startups_with_karma_ids)
  end

  def self.endangered
    startups_with_karma_ids = joins(:karma_points)
      .where(karma_points: { created_at: 3.weeks.ago..Time.now })
      .pluck(:id)
    batched.approved.not_dropped_out.where.not(id: startups_with_karma_ids)
  end

  # Find all by specific category.
  def self.startup_category(category)
    joins(:startup_categories).where(startup_categories: { id: category.id })
  end

  has_many :founders

  validates :product_name, presence: true, uniqueness: { case_sensitive: false, scope: :batch_id }

  has_and_belongs_to_many :startup_categories do
    def <<(_category)
      raise 'Use startup_categories= to enforce startup category limit'
    end
  end

  has_one :batch_application, dependent: :restrict_with_error
  has_many :timeline_events, dependent: :destroy
  has_many :startup_feedback, dependent: :destroy
  has_many :karma_points, dependent: :restrict_with_exception
  has_many :targets, dependent: :destroy, as: :assignee
  has_many :connect_requests, dependent: :destroy
  has_many :team_members, dependent: :destroy

  has_one :admin, -> { where(startup_admin: true) }, class_name: 'Founder', foreign_key: 'startup_id'
  accepts_nested_attributes_for :admin

  belongs_to :batch

  attr_accessor :validate_web_mandatory_fields

  # use the old name attribute as an alias for legal_registered_name
  alias_attribute :name, :legal_registered_name

  # TODO: probable stale attribute
  attr_reader :validate_registration_type

  # TODO: probably stale
  # Registration type is required when registering.
  validates_presence_of :registration_type, if: ->(startup) { startup.validate_registration_type }

  # TODO: probably stale
  # Registration type should be one of Pvt. Ltd., Partnership, or LLC.
  validates :registration_type,
    inclusion: { in: valid_registration_types },
    allow_nil: true

  # Product Progress should be one of acceptable list.
  validates :product_progress,
    inclusion: { in: valid_product_progress_values },
    allow_nil: true,
    allow_blank: true

  validates_numericality_of :pin, allow_nil: true, greater_than_or_equal_to: 100_000, less_than_or_equal_to: 999_999 # PIN Code is always 6 digits

  validates_length_of :product_description,
    maximum: MAX_PRODUCT_DESCRIPTION_CHARACTERS,
    message: "must be within #{MAX_PRODUCT_DESCRIPTION_CHARACTERS} characters"

  validates_length_of :pitch,
    maximum: MAX_PITCH_CHARACTERS,
    message: "must be within #{MAX_PITCH_CHARACTERS} characters"

  # New set of validations for incubation wizard
  store :metadata, accessors: [:updated_from]

  validates_presence_of :product_name

  before_validation do
    # Set registration_type to nil if its set as blank from backend.
    self.registration_type = nil if registration_type.blank?

    # If supplied \r\n for line breaks, replace those with just \n so that length validation works.
    self.product_description = product_description.gsub("\r\n", "\n") if product_description

    # If slug isn't supplied, set one.
    self.slug = generate_randomized_slug if slug.blank?

    # Default product name to 'Untitled Product' if absent
    self.product_name ||= 'Untitled Product'
  end

  before_destroy do
    # Clear out associations from associated Founders (and pending ones).
    Founder.where(startup_id: id).update_all(startup_id: nil, startup_admin: nil)
  end

  # Friendly ID!
  friendly_id :slug
  validates_format_of :slug, with: /\A[a-z0-9\-_]+\z/i, allow_nil: true

  def approved?
    dropped_out != true
  end

  def dropped_out?
    dropped_out == true
  end

  def batched?
    batch.present?
  end

  mount_uploader :logo, LogoUploader
  process_in_background :logo

  normalize_attribute :pitch, :product_description, :email, :phone

  attr_accessor :full_validation

  after_initialize ->() { @full_validation = true }

  normalize_attribute :website do |value|
    case value
      when '' then
        nil
      when nil then
        nil
      when %r{^https?://.*} then
        value
      else
        "http://#{value}"
    end
  end

  normalize_attribute :twitter_link do |value|
    case value
      when %r{^https?://(www\.)?twitter.com.*} then
        value
      when /^(www\.)?twitter\.com.*/ then
        "https://#{value}"
      when '' then
        nil
      when nil then
        nil
      else
        "https://twitter.com/#{value}"
    end
  end

  normalize_attribute :facebook_link do |value|
    case value
      when %r{^https?://(www\.)?facebook.com.*} then
        value
      when /^(www\.)?facebook\.com.*/ then
        "https://#{value}"
      when '' then
        nil
      when nil then
        nil
      else
        "https://facebook.com/#{value}"
    end
  end

  def founder_ids=(list_of_ids)
    founders_list = Founder.find list_of_ids.map(&:to_i).select { |e| e.is_a?(Integer) && e.positive? }
    founders_list.each { |u| founders << u }
  end

  validate :category_count

  def category_count
    return unless @category_count_exceeded || startup_categories.count > MAX_CATEGORY_COUNT
    errors.add(:startup_categories, "Can't have more than 3 categories")
  end

  # Custom setter for startup categories.
  #
  # @param [String, Array] category_entries Array of Categories or comma-separated Category ID-s.
  def startup_categories=(category_entries)
    parsed_categories = if category_entries.is_a? String
      category_entries.split(',').map do |category_id|
        StartupCategory.find(category_id)
      end
    else
      category_entries
    end

    # Enforce maximum count for categories.
    if parsed_categories.count > MAX_CATEGORY_COUNT
      @category_count_exceeded = true
    else
      super parsed_categories
    end
  end

  def self.current_startups_split
    {
      'Approved' => approved.count,
      'Dropped-out' => dropped_out.count
    }
  end

  def agreement_live?
    agreement_signed_at.present? ? agreement_signed_at > AGREEMENT_DURATION.years.ago : false
  end

  def founder?(founder)
    return false unless founder
    founder.startup_id == id
  end

  def possible_founders
    founders + Founder.non_founders
  end

  def phone
    admin.try(:phone)
  end

  def cofounders(founder)
    founders - [founder]
  end

  def generate_randomized_slug
    if product_name.present?
      "#{product_name.parameterize}-#{rand 1000}"
    elsif name.present?
      "#{name.parameterize}-#{rand 1000}"
    else
      "nameless-#{SecureRandom.hex(2)}"
    end
  end

  def regenerate_slug!
    # Create slug from name.
    self.slug = product_name.parameterize

    begin
      save!
    rescue ActiveRecord::RecordNotUnique
      # If it's taken, try adding a random number.
      self.slug = "#{product_name.parameterize}-#{rand 1000}"
      retry
    end
  end

  ####
  # Temporary mentor and investor checks which always return false
  ####
  def mentors?
    false
  end

  def investors?
    false
  end

  # returns the date of the earliest verified timeline entry
  def earliest_team_event_date
    timeline_events.verified_or_needs_improvement.not_private.order(:event_on).first.try(:event_on)
  end

  # returns the date of the latest verified timeline entry
  def latest_team_event_date
    timeline_events.verified_or_needs_improvement.not_private.order(:event_on).last.try(:event_on)
  end

  # returns the latest 'moved_to_x_stage' timeline entry
  def latest_change_of_stage
    timeline_events.verified.where(timeline_event_type: TimelineEventType.moved_to_stage).order(event_on: :desc).includes(:timeline_event_type).first
  end

  # returns all timeline entries posted in the current stage i.e after the last 'moved_to_x_stage' timeline entry
  def current_stage_events
    if latest_change_of_stage.present?
      timeline_events.where('event_on > ?', latest_change_of_stage.event_on)
    else
      timeline_events
    end
  end

  # returns a distinct array of timeline_event_types of all timeline entries posted in the current stage
  def current_stage_event_types
    TimelineEventType.find(current_stage_events.pluck(:timeline_event_type_id).uniq)
  end

  def current_stage
    changed_stage_event = latest_change_of_stage
    changed_stage_event ? changed_stage_event.timeline_event_type.key : TimelineEventType::TYPE_STAGE_IDEA
  end

  # Returns current iteration, counting end-of-iteration events. If at_event is supplied, it calculates iteration during
  # that event.
  def iteration(at_event: nil)
    if at_event
      timeline_events.where('created_at < ?', at_event.created_at)
    else
      timeline_events
    end.end_of_iteration_events.verified.count + 1
  end

  def timeline_verified?
    approved? && timeline_events.verified.present?
  end

  def admin?(founder)
    admin == founder
  end

  def timeline_events_for_display(viewer)
    if viewer && self == viewer.startup
      timeline_events.order(:event_on, :updated_at).reverse_order
    else
      timeline_events.verified_or_needs_improvement.order(:event_on, :updated_at).reverse_order
    end
  end

  # Update stage whenever startup is updated. Note that this is also triggered from TimelineEvent after_commit.
  after_save :update_stage!

  # Update stage stored in database. Do not trigger callbacks, to avoid callback loop.
  def update_stage!
    update_column(:stage, current_stage)
  end

  def latest_help_wanted
    timeline_events.verified.help_wanted.order(created_at: 'desc').first
  end

  def display_name
    label = product_name
    label += " (#{name})" if name.present?
    label
  end

  def self.available_batches
    Batch.where(id: Startup.batched.pluck(:batch_id).uniq)
  end

  def self.leaderboard_of_batch(batch)
    startups_by_points = Startup.not_dropped_out.where(batch: batch)
      .joins(:karma_points)
      .where('karma_points.created_at > ?', leaderboard_start_date)
      .where('karma_points.created_at < ?', leaderboard_end_date)
      .group(:startup_id)
      .sum(:points)
      .sort_by { |_startup_id, points| points }.reverse

    last_points = nil
    last_rank = nil

    startups_by_points.each_with_index.map do |startup_points, index|
      startup_id, points = startup_points

      if last_points == points
        rank = last_rank
      else
        rank = index + 1
        last_rank = rank
      end

      last_points = points

      [startup_id, rank]
    end
  end

  def self.leaderboard_toppers_for_batch(batch, count: 3)
    # returns ids of n toppers on the leaderboard
    leaderboard_of_batch(batch)[0..count - 1].map { |id_and_rank| id_and_rank[0] }
  end

  def self.without_karma_and_rank_for_batch(batch)
    ranked_startup_ids = Startup.not_dropped_out.where(batch: batch)
      .joins(:karma_points)
      .where('karma_points.created_at > ?', leaderboard_start_date)
      .where('karma_points.created_at < ?', leaderboard_end_date)
      .pluck(:startup_id).uniq

    unranked_startups = Startup.not_dropped_out.where(batch: batch)
      .where.not(id: ranked_startup_ids)

    [unranked_startups, ranked_startup_ids.count + 1]
  end

  # Starts on the week before last's Monday 6 PM IST.
  def self.leaderboard_start_date
    if Batch.current.present?
      if monday? && before_evening?
        8.days.ago.beginning_of_week
      else
        7.days.ago.beginning_of_week
      end
    else
      (Batch.last.end_date - 7.days).beginning_of_week
    end.in_time_zone('Asia/Calcutta') + 18.hours
  end

  # Ends on last week's Monday 6 PM IST.
  def self.leaderboard_end_date
    if Batch.current.present?
      if monday? && before_evening?
        8.days.ago.end_of_week
      else
        7.days.ago.end_of_week
      end
    else
      (Batch.last.end_date - 7.days).end_of_week
    end.in_time_zone('Asia/Calcutta') + 18.hours
  end

  # UPDATE: commenting out below code as it appears a simple call to short_url from view in fact creates short urls on the go if they are absent
  # # generate/clean up shortened urls for external links
  # after_save :update_shortened_urls
  #
  # def update_shortened_urls
  #   # all the attributes that need a shortened url
  #   external_links = ["presentation_link", "wireframe_link", "prototype_link", "product_video_link"]
  #
  #   # create new shortened url for any new attribute in the external_links list
  #   # TODO: Probably rewrite without the use of eval ?
  #   external_links.each do |link|
  #     eval "next unless #{link}_changed?"
  #     eval "Shortener::ShortenedUrl.generate(#{link})"
  #
  #     # TODO: delete stale shortened url entry for old value
  #   end
  # end

  # Registration token must be set before startup can be created - equal to startup_token of team lead.
  attr_accessor :registration_token

  after_create :assign_founders

  # Use registration_token to link founders.
  def assign_founders
    return if registration_token.blank?

    # Assign founders to startup, and wipe the startup token to indicate completion of this event.
    Founder.where(startup_token: registration_token).update_all(startup_id: id, startup_token: nil)
  end

  class << self
    private

    def monday?
      Date.today.in_time_zone('Asia/Calcutta').wday == 1
    end

    def before_evening?
      Time.now.in_time_zone('Asia/Calcutta').hour < 18
    end
  end
end
