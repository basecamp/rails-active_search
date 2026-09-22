module ActiveSearch
  module Schema # :nodoc: all
    # One structure that satisfies an index's requirements, which is not the same as the
    # requirements: several structures satisfy them. native is what the adapter hands its store.
    CreationPlan = Data.define(:index_name, :native, :describes, :applied) do
      # applied says whether the structure exists now. A database plan is a migration nobody has
      # run, so what it describes does not exist until they do.
      def initialize(index_name:, native:, describes:, applied: true)
        super(index_name: index_name, native: native, describes: describes, applied: applied)
      end

      def summary
        width = describes.keys.map(&:length).max

        describes.map { |name, kind| "  #{name.to_s.ljust(width)}  #{kind}" }
      end
    end
  end
end
