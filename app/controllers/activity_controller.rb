# Account activity: the audit trail, shown to the account it belongs to.
class ActivityController < ApplicationController
  PER_PAGE = 50

  def index
    # includes(:subject): Event#description reads the polymorphic subject when
    # the metadata carries no name, which would otherwise be one query per row.
    @events = current_user.events.includes(:subject).recent_first.limit(PER_PAGE)
  end
end
