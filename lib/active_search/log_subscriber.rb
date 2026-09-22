# frozen_string_literal: true

module ActiveSearch
  class LogSubscriber < ActiveSupport::LogSubscriber # :nodoc:
    LABEL = "ActiveSearch"

    subscribe_log_level :search, :debug
    subscribe_log_level :add, :debug
    subscribe_log_level :remove, :debug
    subscribe_log_level :flush_batch, :debug
    subscribe_log_level :remove_by_filter, :debug

    def search(event)
      debug do
        payload = filter(event.payload.slice(:index, :store_name, :query_length, :total, :total_relation))
        "  #{color(LABEL + " Search", MAGENTA, bold: true)} (#{event.duration.round(1)}ms)  #{payload.inspect}"
      end
    end

    def add(event)
      debug do
        payload = filter(event.payload.slice(:index, :store_name, :document_id))
        "  #{color(LABEL + " Add", MAGENTA, bold: true)} (#{event.duration.round(1)}ms)  #{payload.inspect}"
      end
    end

    def remove(event)
      debug do
        payload = filter(event.payload.slice(:index, :store_name, :document_id))
        "  #{color(LABEL + " Remove", MAGENTA, bold: true)} (#{event.duration.round(1)}ms)  #{payload.inspect}"
      end
    end

    def flush_batch(event)
      debug do
        payload = filter(event.payload.slice(:index, :store_name, :operations))
        "  #{color(LABEL + " Batch", MAGENTA, bold: true)} (#{event.duration.round(1)}ms)  #{payload.inspect}"
      end
    end

    def remove_by_filter(event)
      debug do
        payload = filter(event.payload.slice(:index, :store_name, :removed))
        "  #{color(LABEL + " Remove By Filter", MAGENTA, bold: true)} (#{event.duration.round(1)}ms)  #{payload.inspect}"
      end
    end

    private
      def filter(payload)
        ActiveSearch.parameter_filter.filter(payload)
      end
  end
end

ActiveSearch::LogSubscriber.attach_to :active_search
