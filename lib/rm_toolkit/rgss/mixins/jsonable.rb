module RgssDb
  module Jsonable
    def as_json
      hash = {}
      hash.store("json_class", self.class.name)
      instance_variables.each do |ivar|
        value = instance_variable_get(ivar)
        hash.store(ivar.to_s.delete("@"), value.respond_to?(:as_json) ? value.as_json : value)
      end
      hash
    end

    def to_json(*args)
      Oj.dump(as_json, mode: :compat)
    end
  end
end
