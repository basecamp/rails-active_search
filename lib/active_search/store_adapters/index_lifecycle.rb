module ActiveSearch
  module StoreAdapters
    # The half of an adapter that describes and builds an index, rather than searching it. Optional
    # but for observe_index, which a typed adapter must implement unless it overrides
    # prepare_document. Every other NotImplementedError here may stand, and Solr's do.
    #
    # Not named Schema: a bare Schema in an adapter would find this before ActiveSearch::Schema.
    module IndexLifecycle # :nodoc:
      # What a live index must provide for this index's declared queries to work. Named as the
      # store names them, because that is what it reports back.
      def schema_requirements(index)
        index.definition.fields.map do |field|
          Schema::Requirement.new(field: field.name, role: field.role, name: field.name,
            native_type: expected_native_type(field))
        end
      end

      # What this engine calls a field of that declared type, where it has a name for one. Checking
      # it is what stops a keyword satisfying an integer, or a scalar a collection: both are merely
      # filterable. nil where the engine does not type a field.
      def expected_native_type(field)
        nil
      end

      # What the store says it holds. Each adapter decides which failure means the index is not
      # there, rather than that the store did not answer.
      def inspect_schema(index)
        Schema::Inspection.new(state: :found, observed: observe_index(index))
      rescue *inspection_errors => e
        Schema::Inspection.new(**(missing_index?(e) ? { state: :missing } :
          { state: :unavailable, detail: e.message }))
      end

      # AdapterError as well as the client's own, because an adapter that reads its schema through
      # the gem's request path meets that one instead.
      def inspection_errors
        self.class::CLIENT_ERRORS + [ AdapterError ]
      end

      # An Array of Schema::Observation, one per field the store says it holds, named as the store
      # names it. Everything else turns on this: verification matches requirements against them, and
      # a write narrows to their names, so a field left out is a field not written. One field may
      # need several, one per role it really fills.
      def observe_index(index)
        raise NotImplementedError, "#{self.class.name.demodulize} cannot report an index's schema"
      end

      def missing_index?(error)
        false
      end

      # Removes the index and everything in it. Not offered as a task: dropping every index in every
      # store is the wrong thing to put one command away. An adapter overrides perform_drop, never
      # this, so the cache reset cannot be skipped.
      def drop_index(index)
        translating_errors { perform_drop(index) }
      ensure
        reset_schema_cache(index)
      end

      def perform_drop(index)
        raise NotImplementedError, "#{self.class.name.demodulize} cannot drop an index"
      end

      # Why this store would refuse to build this index, if it would. Asked before status names a
      # command, so it does not send anyone to one that always refuses.
      def creation_refusal(index)
        nil
      end

      # Whether an index here is backed by a model the application owns, which only a generator
      # can write.
      def generates_document_class?
        false
      end

      # One structure that would satisfy this index's requirements.
      def creation_plan(index)
        raise NotImplementedError, "#{self.class.name.demodulize} cannot create an index"
      end

      # Builds what a composed plan describes. Abstract like creation_plan: an adapter that composes
      # a plan without saying how to apply it must fail by contract.
      def apply_creation_plan(plan)
        raise NotImplementedError, "#{self.class.name.demodulize} cannot create an index"
      end

      # Create the index, or refuse. A refusal reports what is there and never who built it.
      def create_index(index)
        inspection = inspect_schema(index)
        refuse_unreachable!(index, inspection)

        if inspection.found?
          built(index, inspection)
        else
          plan = composed(index)
          apply_creation_plan(plan)
          reset_schema_cache(index)
          plan
        end
      end

      private
        # NotImplementedError is a ScriptError, so a bare rescue misses it. Only the compose call.
        def composed(index)
          creation_plan(index)
        rescue NotImplementedError => e
          raise Schema::CreationRefused, e.message
        end

        def built(index, inspection)
          verification = Schema::Verification.of(index.index_name, schema_requirements(index), inspection)

          if verification.compatible?
            Schema::CreationPlan.new(index_name: index.index_name, native: nil,
              describes: { index.index_name.to_s => "already built" })
          else
            raise Schema::CreationRefused, "#{index.index_name} is #{verification.describe}."
          end
        end

        # A store that is not answering cannot be said to be empty, so it is nowhere to create.
        def refuse_unreachable!(index, inspection)
          if inspection.unavailable?
            raise Schema::CreationRefused,
              "#{index.index_name} is on a store that is not answering: #{inspection.detail}"
          end
        end
    end
  end
end
