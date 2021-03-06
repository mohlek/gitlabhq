module Ci
  class GitlabCiYamlProcessor
    class ValidationError < StandardError;end

    DEFAULT_STAGES = %w(build test deploy)
    DEFAULT_STAGE = 'test'
    ALLOWED_YAML_KEYS = [:before_script, :image, :services, :types, :stages, :variables]
    ALLOWED_JOB_KEYS = [:tags, :script, :only, :except, :type, :image, :services, :allow_failure, :type, :stage, :when]

    attr_reader :before_script, :image, :services, :variables

    def initialize(config)
      @config = YAML.load(config)

      unless @config.is_a? Hash
        raise ValidationError, "YAML should be a hash"
      end

      @config = @config.deep_symbolize_keys

      initial_parsing

      validate!
    end

    def builds_for_stage_and_ref(stage, ref, tag = false)
      builds.select{|build| build[:stage] == stage && process?(build[:only], build[:except], ref, tag)}
    end

    def builds
      @jobs.map do |name, job|
        build_job(name, job)
      end
    end

    def stages
      @stages || DEFAULT_STAGES
    end

    private

    def initial_parsing
      @before_script = @config[:before_script] || []
      @image = @config[:image]
      @services = @config[:services]
      @stages = @config[:stages] || @config[:types]
      @variables = @config[:variables] || {}
      @config.except!(*ALLOWED_YAML_KEYS)

      # anything that doesn't have script is considered as unknown
      @config.each do |name, param|
        raise ValidationError, "Unknown parameter: #{name}" unless param.is_a?(Hash) && param.has_key?(:script)
      end

      unless @config.values.any?{|job| job.is_a?(Hash)}
        raise ValidationError, "Please define at least one job"
      end

      @jobs = {}
      @config.each do |key, job|
        stage = job[:stage] || job[:type] || DEFAULT_STAGE
        @jobs[key] = { stage: stage }.merge(job)
      end
    end

    def process?(only_params, except_params, ref, tag)
      return true if only_params.nil? && except_params.nil?

      if only_params
        return true if tag && only_params.include?("tags")
        return true if !tag && only_params.include?("branches")
        
        only_params.find do |pattern|
          match_ref?(pattern, ref)
        end
      else
        return false if tag && except_params.include?("tags")
        return false if !tag && except_params.include?("branches")

        except_params.each do |pattern|
          return false if match_ref?(pattern, ref)
        end
      end
    end

    def build_job(name, job)
      {
        stage_idx: stages.index(job[:stage]),
        stage: job[:stage],
        commands: "#{@before_script.join("\n")}\n#{normalize_script(job[:script])}",
        tag_list: job[:tags] || [],
        name: name,
        only: job[:only],
        except: job[:except],
        allow_failure: job[:allow_failure] || false,
        when: job[:when] || 'on_success',
        options: {
          image: job[:image] || @image,
          services: job[:services] || @services
        }.compact
      }
    end

    def match_ref?(pattern, ref)
      if pattern.first == "/" && pattern.last == "/"
        Regexp.new(pattern[1...-1]) =~ ref
      else
        pattern == ref
      end
    end

    def normalize_script(script)
      if script.is_a? Array
        script.join("\n")
      else
        script
      end
    end

    def validate!
      unless validate_array_of_strings(@before_script)
        raise ValidationError, "before_script should be an array of strings"
      end

      unless @image.nil? || @image.is_a?(String)
        raise ValidationError, "image should be a string"
      end

      unless @services.nil? || validate_array_of_strings(@services)
        raise ValidationError, "services should be an array of strings"
      end

      unless @stages.nil? || validate_array_of_strings(@stages)
        raise ValidationError, "stages should be an array of strings"
      end

      unless @variables.nil? || validate_variables(@variables)
        raise ValidationError, "variables should be a map of key-valued strings"
      end

      @jobs.each do |name, job|
        validate_job!(name, job)
      end

      true
    end

    def validate_job!(name, job)
      if name.blank? || !validate_string(name)
        raise ValidationError, "job name should be non-empty string"
      end

      job.keys.each do |key|
        unless ALLOWED_JOB_KEYS.include? key
          raise ValidationError, "#{name} job: unknown parameter #{key}"
        end
      end

      if !validate_string(job[:script]) && !validate_array_of_strings(job[:script])
        raise ValidationError, "#{name} job: script should be a string or an array of a strings"
      end

      if job[:stage]
        unless job[:stage].is_a?(String) && job[:stage].in?(stages)
          raise ValidationError, "#{name} job: stage parameter should be #{stages.join(", ")}"
        end
      end

      if job[:image] && !validate_string(job[:image])
        raise ValidationError, "#{name} job: image should be a string"
      end

      if job[:services] && !validate_array_of_strings(job[:services])
        raise ValidationError, "#{name} job: services should be an array of strings"
      end

      if job[:tags] && !validate_array_of_strings(job[:tags])
        raise ValidationError, "#{name} job: tags parameter should be an array of strings"
      end

      if job[:only] && !validate_array_of_strings(job[:only])
        raise ValidationError, "#{name} job: only parameter should be an array of strings"
      end

      if job[:except] && !validate_array_of_strings(job[:except])
        raise ValidationError, "#{name} job: except parameter should be an array of strings"
      end

      if job[:allow_failure] && !job[:allow_failure].in?([true, false])
        raise ValidationError, "#{name} job: allow_failure parameter should be an boolean"
      end

      if job[:when] && !job[:when].in?(%w(on_success on_failure always))
        raise ValidationError, "#{name} job: when parameter should be on_success, on_failure or always"
      end
    end

    private

    def validate_array_of_strings(values)
      values.is_a?(Array) && values.all? { |value| validate_string(value) }
    end

    def validate_variables(variables)
      variables.is_a?(Hash) && variables.all? { |key, value| validate_string(key) && validate_string(value) }
    end

    def validate_string(value)
      value.is_a?(String) || value.is_a?(Symbol)
    end
  end
end
