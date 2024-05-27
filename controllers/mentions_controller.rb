# -*- encoding : utf-8 -*-

class User::MentionsController < ApplicationController
  include CsrfNonVerifiable

  skip_before_filter :skip_subdomain_calls
  prepend_before_filter :share_with_portfolio_manager, :only => [:show, :index]
  before_filter :login_required
  before_filter :portfolio_shared_layout, only: [:index]

  respond_to :html
  respond_to :json, only: [:index, :mark, :mark_as_unread]

  def index
    load_unread_mentions

    @mobile_ready = true
    @my_mentions = true
    @nav_title = @title = I18n.t("controllers.user.mentions.index.page_title")

    respond_to do |format|
      format.html do
        @is_mentions_page = true
      end

      format.js do
        response.headers["Cache-Control"] = "no-cache, no-store, max-age=0, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        reorder_mentions
      end

      format.json do
        if params[:fnh] == '1' || params[:fp] == '1'
          full_page = params[:fp] == '1'
          if full_page
            @mentions = @mentions.includes(event: :space)
            mentions_count = @mentions.count
          else
            @mentions = @mentions.unread.limit(5)
            mentions_count = @user_mentions.unread.count
          end

          mentions = {
            mentions: NotificationCenter::MentionsMaster.new(mentions: @mentions, user: logged_user, session: session, load_space: full_page).mentions_as_presentable,
            mentions_count: mentions_count,
            show_mentions_info: logged_user.show_mentions_info?
          }

          if full_page
            mentions.update(
              page: @page,
              last_page: @mentions.last_page?
            )
          end
        else
          mentions = @mentions.display_json(logged_user, session)
        end

        respond_with mentions
      end
    end
  end

  def show
    mention = logged_user.mark_mention_as_read(params[:id])
    load_unread_mentions
    send_realtime_updates(mention, :deleted)

    notify_user(operation: 'mark', id: mention.id)

    redirect_to MentionPresenter.new(mention, logged_user, session).link
  end

  def mark
    @mention_id = params[:id]
    logged_user.mark_mention_as_read(@mention_id)
    notify_user(operation: 'mark', id: @mention_id)
    load_unread_mentions
    if mention = logged_user.mentions.find_by_id(@mention_id)
      send_realtime_updates(mention, :deleted)
    end

    respond_to do |format|
      format.html { redirect_to mentions_path }
      format.js do
        reorder_mentions
        response.headers["Cache-Control"] = "no-cache, no-store, max-age=0, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        @new_mention = @mentions.last if @mentions.present?
      end
      format.json { render json: {} }
    end
  end

  def mark_as_unread
    @mention_id = params[:id]
    mention = logged_user.mark_mention_as_unread(@mention_id)
    send_realtime_updates(mention, :added) if mention

    respond_to do |format|
      format.html { redirect_to mentions_path }
      format.json { render json: {} }
    end
  end

  def mark_all
    logged_user.unread_mentions.each { |mention| send_realtime_updates(mention, :deleted) }
    logged_user.mark_mentions_as_read
    @marked_all = true

    notify_user(:operation => 'mark_all')
    respond_to do |format|
      format.html { redirect_to mentions_path }
      format.js &mark_response
      format.json { render json: {} }
    end
  end

  def close_info
    logged_user.settings.update_attribute(:show_mentions_info, false)

    respond_to do |format|
      format.html { redirect_to mentions_path }
      format.js
    end
  end

  def client_view
    load_unread_mentions
    respond_to do |format|
      format.js do
        @mentions = @mentions.for_tickets
        reorder_mentions
        render :client_view
      end
    end
  end

  private

  def load_unread_mentions
    @user_mentions = logged_user.mentions
    @mentions = @user_mentions.page(@page).per(MentionsSettings.page_limit(Mention::PER_PAGE)).with_event_and_author
  end

  def reorder_mentions
    @mentions = @mentions.unread.per(MentionsSettings.page_limit).reorder('mentions.id ASC') unless params[:page]
  end

  def mark_response
    Proc.new do
      load_unread_mentions
      @mentions = @mentions.unread
    end
  end

  def notify_user(opts={})
    Breakout::MQ.headers(
      :user_id => logged_user.id,
      :message => {:payload => opts, :type => "mention"}
    )
  end

  def send_realtime_updates(mention, operation)
    deliveryman = RealTime::Deliveryman::Base.for(:mentions)

    case operation
    when :deleted
      new_mention = @mentions.unread.per(MentionsSettings.page_limit).last if @mentions
      deliveryman.mention_removed(mention: mention, new_mention: new_mention)
    when :added
      deliveryman.mention_added(mention: mention)
    end
  end
end
