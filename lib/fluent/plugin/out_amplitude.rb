module Fluent
  # Fluent::AmplitudeOutput plugin
  class AmplitudeOutput < Fluent::BufferedOutput
    Fluent::Plugin.register_output('amplitude', self)

    include Fluent::HandleTagNameMixin

    config_param :api_key, :string, secret: true
    config_param :device_id_key, :string
    config_param :user_id_key, :string
    config_param :user_properties, :array, default: nil
    config_param :event_properties, :array, default: nil
    config_param :properties_blacklist, :array, default: nil
    config_param :events_whitelist, :array, default: nil
    class AmplitudeError < StandardError
    end

    def initialize
      super
      require 'amplitude-api'
    end

    def configure(conf)
      super
      raise Fluent::ConfigError, "'api_key' must be specified." if @api_key.nil?

      invalid = @device_id_key.nil? && @user_id_key.nil?
      raise Fluent::ConfigError,
            "'device_id_key' or 'user_id_key' must be specified." if invalid
    end

    def start
      super
      AmplitudeAPI.api_key = @api_key
    end

    def format(tag, time, record)
      return if @events_whitelist && !@events_whitelist.include?(tag)

      amplitude_hash = {
        event_type: tag
      }

      record = filter_properties_blacklist(record)

      amplitude_hash, record = extract_user_and_device(amplitude_hash, record)

      unless amplitude_hash[:user_id] || amplitude_hash[:device_id]
        raise AmplitudeError, 'Error: either user_id or device_id must be set'
      end

      amplitude_hash, record = extract_user_properties(amplitude_hash, record)

      amplitude_hash = extract_event_properties(amplitude_hash, record)

      [tag, time, amplitude_hash].to_msgpack
    end

    def write(chunk)
      records = []
      chunk.msgpack_each do |_tag, _time, record|
        records << AmplitudeAPI::Event.new(simple_symbolize_keys(record))
      end

      send_to_amplitude(records)
    end

    private

    def filter_properties_blacklist(record)
      if @properties_blacklist
        record.reject { |k,v| @properties_blacklist.include?(k) }
      else
        record
      end
    end

    def extract_user_and_device(amplitude_hash, record)
      if @user_id_key && record[@user_id_key]
        amplitude_hash[:user_id] = record.delete(@user_id_key)
      end

      if @device_id_key && record[@device_id_key]
        amplitude_hash[:device_id] = record.delete(@device_id_key)
      end

      [amplitude_hash, record]
    end

    def extract_user_properties(amplitude_hash, record)
      # if user_properties are specified, pull them off of the record
      if @user_properties
        amplitude_hash[:user_properties] = {}.tap do |user_properties|
          @user_properties.each do |prop|
            next unless record[prop]
            user_properties[prop.to_sym] = record.delete(prop)
          end
        end
      end
      [amplitude_hash, record]
    end

    def extract_event_properties(amplitude_hash, record)
      # if event_properties are specified, pull them off of the record
      # otherwise, use the remaining record (minus any user_properties)
      amplitude_hash[:event_properties] = begin
        if @event_properties
          record.select do |k, _v|
            @event_properties.include?(k)
          end
        else
          record
        end
      end
      amplitude_hash
    end

    def send_to_amplitude(records)
      log.info("sending #{records.length} to amplitude")
      begin
        res = AmplitudeAPI.track(records)
        unless res.response_code == 200
          raise "Got #{res.response_code} #{res.body} from AmplitudeAPI"
        end
      rescue StandardError => e
        raise AmplitudeError, "Error: #{e.message}"
      end
    end

    def simple_symbolize_keys(hsh)
      Hash[hsh.map do |k, v|
        begin
          [k.to_sym, v]
        rescue
          [k, v]
        end
      end]
    end
  end
end
