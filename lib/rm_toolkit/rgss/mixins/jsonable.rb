require 'set'

module RgssDb
  module Jsonable
    def as_json
      hash = {}
      hash.store("json_class", self.class.name)
      instance_variables.each do |ivar|
        value = instance_variable_get(ivar)
        hash.store(ivar.to_s.delete("@"), json_clean(value))
      end
      hash
    end

    def to_json(*args)
      Oj.dump(as_json, mode: :compat)
    end

    private

    def json_clean(value)
      case value
      when Hash
        if value.keys.any? { |k| !k.is_a?(String) && !k.is_a?(Symbol) }
          value.each_with_object({}) { |(k, v), h| h[k.to_s] = json_leaf(v) }
        else
          value.transform_values { |v| json_leaf(v) }
        end
      else
        json_leaf(value)
      end
    end

    def json_leaf(value)
      case value
      when Array
        value.map { |v| json_leaf_tracked(v) }
      when ->(v) { v.respond_to?(:as_json) }
        json_leaf_tracked(value)
      else
        value
      end
    end

    def json_leaf_tracked(value)
      visited = (Thread.current[:jsonable_visited] ||= Set.new)
      return value unless value.respond_to?(:object_id)
      return value if value.is_a?(Numeric) || value.is_a?(Symbol) || value.is_a?(TrueClass) || value.is_a?(FalseClass)
      oid = value.object_id
      return nil if visited.include?(oid)
      visited.add(oid)
      result = value.respond_to?(:as_json) ? value.as_json : value
      visited.delete(oid)
      result
    end
  end
end
