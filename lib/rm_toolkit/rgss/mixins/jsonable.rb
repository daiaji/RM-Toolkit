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
        value.map { |v| v.respond_to?(:as_json) ? v.as_json : v }
      when ->(v) { v.respond_to?(:as_json) }
        value.as_json
      else
        value
      end
    end
  end
end
