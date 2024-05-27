# -*- encoding : utf-8 -*-
# == Schema Information
# Schema version: 20120607184827
#
# Table name: mentions
#
#  id                                  :integer not null, primary key
#  user_id                             :string(22)
#  author_id                           :string(22)
#  event_id                            :string(22)
#  link                                :string(255)
#  message                             :string(255)
#  read                                :boolean(1)
#  created_at                          :datetime
#  updated_at                          :datetime

class Mention < ActiveRecord::Base
  belongs_to :user, inverse_of: :mentions
  belongs_to :event
  belongs_to_with_deleted :author, class_name: 'User', foreign_key: 'author_id'

  after_create :notify_user

  default_scope -> { order("mentions.id DESC") }

  scope :read, -> { where("mentions.read") }
  scope :unread, -> { where("!mentions.read") }
  scope :created_from, lambda { |date_start| where("mentions.created_at >= ?", date_start) }
  scope :with_event_and_author, -> { includes(:event, :author) }
  scope :for_tickets, -> { where("link REGEXP '#{TICKET_REGEX}' OR link REGEXP '#{TICKET_COMMENT_REGEX}'")}
  scope :for_ticket_comments, -> { where("link regexp '#{TICKET_COMMENT_REGEX}'")}

  TICKET_REGEX = "tickets/[0-9]+$"
  TICKET_COMMENT_REGEX = "tickets/([0-9]+)(.+)comment=[0-9]+"
  PER_PAGE = 15

  def created_date
    created_at.utc.strftime("%Y-%m-%d")
  end

  def notify_user
    Breakout::MQ.headers(:user_id => user_id, :message => {
      :payload => {:operation => 'new', :message => message},
      :type => "mention",
    })
    log_create(user_id: author_id, skip_alerts: true)
  end

  def self.display_json(logged_user, session)
    unread.map do |mention|
      {
        id: mention.id, link: mention.link, message: mention.message, updated_at: mention.updated_at,
        user: {
          name: mention.author.permissioned_name(logged_user),
          picture: Breakout::AvatarGenerator.new(mention.author, session, { viewer: logged_user, small: true }).avatar_path
        }
      }
    end.to_json
  end

  def ticket_id
    return obj_id.to_i if link =~ Regexp.new(TICKET_REGEX)

    if link =~ Regexp.new(TICKET_COMMENT_REGEX)
      ticket_comment = TicketComment.find_by_id(event.obj_id)
      return ticket_comment.ticket_id if ticket_comment
    end
  end
end
