require "timeout"

module ActiveSearch
  module Schema # :nodoc: all
    extend ActiveSupport::Autoload

    eager_autoload do
      autoload :CreationPlan
      autoload :CreationRefused
      autoload :Inspection
      autoload :Observation
      autoload :ObservationCache
      autoload :Requirement
      autoload :Verification
    end

    # One store that does not answer must not hold up the rest.
    DEFAULT_TIMEOUT = 5

    class << self
      # Does this index still provide what its declaration needs.
      def verify(index, timeout: nil)
        seconds = timeout || DEFAULT_TIMEOUT
        # Upgraded once the store resolves, so the rescue need not re-resolve what may have failed.
        name = index.name

        Timeout.timeout(seconds) do
          store = index.store
          name = index.index_name_for(store)
          Verification.of(name, store.schema_requirements(index), store.inspect_schema(index))
        end
      rescue Timeout::Error
        Verification.unavailable(name, "did not answer within #{seconds}s")
      rescue NotImplementedError => e
        Verification.unsupported(name, e.message)
      rescue StandardError => e
        # One index that fails must not stop a run over the rest, but it is reported as a failure
        # rather than as a store that cannot answer.
        Verification.error(name, "#{e.class}: #{e.message}")
      end

      # How many documents the index holds. :not_applicable where the schema did not verify, and
      # :unknown where the store could not answer — never zero for either.
      def population_of(index, verification, timeout: nil)
        if %i[ compatible incompatible ].include?(verification.outcome)
          Timeout.timeout(timeout || DEFAULT_TIMEOUT) { index.search(nil).limit(1).results.total }
        else
          :not_applicable
        end
      rescue ActiveSearch::Error, ActiveRecord::ActiveRecordError, Timeout::Error
        :unknown
      end

      # Nil unless there is a command that would work.
      def next_step_for(index, verification)
        if %i[ missing unsupported ].include?(verification.outcome)
          creation_refusal_for(index) || creation_command_for(index)
        end
      end

      # A store can advertise creation and still refuse this particular declaration.
      def creation_refusal_for(index)
        index.store.creation_refusal(index)
      rescue NotImplementedError
        nil
      end

      def creation_command_for(index)
        if index.store.generates_document_class?
          "rails generate active_search:document #{index.name}, then rails db:migrate"
        elsif creates_indexes?(index.store)
          "rails active_search:index:create INDEX=#{index.name}"
        else
          "#{store_label(index)} cannot create an index. Create it in the store."
        end
      end

      # A store that cannot say what it supports is not one to assume can build an index.
      def creates_indexes?(store)
        store.capabilities.supports_index_creation?
      rescue NotImplementedError
        false
      end

      # An adapter is public API and can be an anonymous class, which has no name at all.
      def store_label(index)
        index.store.class.name&.demodulize&.underscore || "adapter"
      end
    end
  end
end
