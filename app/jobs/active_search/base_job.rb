module ActiveSearch
  class BaseJob < ActiveJob::Base # :nodoc:
    queue_as :active_search

    # Record deleted between enqueue and execution is a normal race—discard silently. Only that:
    # ActiveJob wraps every deserialization failure in this class, a connection error included,
    # and discarding one of those drops a committed write with no retry.
    # Two record-gone classes: GlobalID's own RecordNotFound sits outside ActiveRecord's hierarchy.
    RECORD_GONE = [ ActiveRecord::RecordNotFound, GlobalID::Locator::RecordNotFound ].freeze

    rescue_from ActiveJob::DeserializationError do |error|
      raise error unless RECORD_GONE.any? { |gone| error.cause.is_a?(gone) }
    end

    ActiveSupport.run_load_hooks(:active_search_job, self)
  end
end
