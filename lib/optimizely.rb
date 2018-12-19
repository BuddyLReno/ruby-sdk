# frozen_string_literal: true

#
#    Copyright 2016-2018, Optimizely and contributors
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
require_relative 'optimizely/audience'
require_relative 'optimizely/decision_service'
require_relative 'optimizely/error_handler'
require_relative 'optimizely/event_builder'
require_relative 'optimizely/event_dispatcher'
require_relative 'optimizely/exceptions'
require_relative 'optimizely/helpers/constants'
require_relative 'optimizely/helpers/group'
require_relative 'optimizely/helpers/validator'
require_relative 'optimizely/helpers/variable_type'
require_relative 'optimizely/logger'
require_relative 'optimizely/notification_center'
require_relative 'optimizely/project_config'

module Optimizely
  # The Optimizely client class containing an API to interact with Optimizely programmatically.
  # For more information, see https://docs.developers.optimizely.com/full-stack/docs/instantiate.

  class Project
    attr_reader :notification_center
    # @api no-doc
    attr_reader :is_valid, :config, :decision_service, :error_handler,
                :event_builder, :event_dispatcher, :logger

    # Constructor for Projects.
    #
    # See https://github.com/optimizely/ruby-sdk/blob/master/lib/optimizely.rb for more information.
    #
    # @param datafile             [string]               The JSON string representing the project.
    # @param event_dispatcher     [event_dispatcher]     An event handler to manage network calls.
    # @param logger               [logger]               logger object to log issues.
    # @param error_handler        [error_handler]        An error handler object to handle errors.
    #                                                    By default all exceptions will be suppressed.
    # @param user_profile_service [user_profile_service] A user profile service.
    # @param skip_json_validation [skip_json_validation] Specifies whether the JSON is validated. Set to `true` to 
    #                                                    skip JSON validation on the schema, or `false` to perform validation.
    def initialize(datafile, event_dispatcher = nil, logger = nil, error_handler = nil, skip_json_validation = false, user_profile_service = nil)
      @is_valid = true
      @logger = logger || NoOpLogger.new
      @error_handler = error_handler || NoOpErrorHandler.new
      @event_dispatcher = event_dispatcher || EventDispatcher.new
      @user_profile_service = user_profile_service

      begin
        validate_instantiation_options(datafile, skip_json_validation)
      rescue InvalidInputError => e
        @is_valid = false
        @logger = SimpleLogger.new
        @logger.log(Logger::ERROR, e.message)
        return
      end

      begin
        @config = ProjectConfig.new(datafile, @logger, @error_handler)
      rescue StandardError => e
        @is_valid = false
        @logger = SimpleLogger.new
        error_msg = e.class == InvalidDatafileVersionError ? e.message : InvalidInputError.new('datafile').message
        error_to_handle = e.class == InvalidDatafileVersionError ? InvalidDatafileVersionError : InvalidInputError
        @logger.log(Logger::ERROR, error_msg)
        @error_handler.handle_error error_to_handle
        return
      end

      @decision_service = DecisionService.new(@config, @user_profile_service)
      @event_builder = EventBuilder.new(@config, @logger)
      @notification_center = NotificationCenter.new(@logger, @error_handler)
    end

    # Activates an A/B test for a user, determines whether they qualify for the experiment, buckets a qualified
    # user into a variation, and sends an impression event to Optimizely.
    #
    # This method takes into account the user `attributes` passed in, to determine if the user
    # is part of the audience that qualifies for the experiment.
    #
    # For more information, see https://github.com/optimizely/ruby-sdk/blob/master/lib/optimizely.rb.
    #
    # @param experiment_key [string]  The key of the variation's experiment to activate.
    # @param user_id        [string]  The user ID.
    # @param attributes     [map]     A map of custom key-value string pairs specifying attributes for the user.
    #
    # @return               [String]  The key of the variation where the user is bucketed, or `nil` if the 
    #                                 user doesn't qualify for the experiment.

    def activate(experiment_key, user_id, attributes = nil)
      unless @is_valid
        @logger.log(Logger::ERROR, InvalidDatafileError.new('activate').message)
        return nil
      end

      return nil unless Optimizely::Helpers::Validator.inputs_valid?(
        {
          experiment_key: experiment_key,
          user_id: user_id
        }, @logger, Logger::ERROR
      )

      variation_key = get_variation(experiment_key, user_id, attributes)

      if variation_key.nil?
        @logger.log(Logger::INFO, "Not activating user '#{user_id}'.")
        return nil
      end

      # Create and dispatch impression event
      experiment = @config.get_experiment_from_key(experiment_key)
      send_impression(experiment, variation_key, user_id, attributes)

      variation_key
    end

    # Buckets a qualified user into an A/B test. Takes the same arguments and returns the same values as `activate`, 
    # but without sending an impression network request. The behavior of the two methods is identical otherwise. 
    # Use `getVariation` if `activate` has been called and the current variation assignment is needed for a given
    # experiment and user.

    # This method takes into account the user `attributes` passed in, to determine if the user
    # is part of the audience that qualifies for the experiment.
    #     
    # For more information, see https://docs.developers.optimizely.com/full-stack/docs/get-variation
    #
    # @param experiment_key [string]    The key of the experiment for which to retrieve the variation.
    # @param user_id        [string]    The ID of the user for whom to retrieve the variation.
    # @param attributes     [map]       A map of custom key-value string pairs specifying attributes for the user.
    #
    # @return               [variation] The key of the variation where the user is bucketed, or `nil` if the user
    #                                   doesn't qualify for the experiment.
    def get_variation(experiment_key, user_id, attributes = nil)
      unless @is_valid
        @logger.log(Logger::ERROR, InvalidDatafileError.new('get_variation').message)
        return nil
      end

      return nil unless Optimizely::Helpers::Validator.inputs_valid?(
        {
          experiment_key: experiment_key,
          user_id: user_id
        }, @logger, Logger::ERROR
      )

      unless user_inputs_valid?(attributes)
        @logger.log(Logger::INFO, "Not activating user '#{user_id}.")
        return nil
      end

      variation_id = @decision_service.get_variation(experiment_key, user_id, attributes)

      unless variation_id.nil?
        variation = @config.get_variation_from_id(experiment_key, variation_id)
        return variation['key'] if variation
      end
      nil
    end

    # Forces a user into a variation for a given experiment for the lifetime of the Optimizely client.
    # The forced variation value doesn't persist across application launches.
    #
    # For more information, see https://docs.developers.optimizely.com/full-stack/docs/set-forced-variation.
    #
    # @param experiment_key  [string]  The key of the experiment to set with the forced variation.
    # @param user_id         [string]  The ID of the user to force into the variation.
    # @param variation_key   [string]  The key of the forced variation. 
    #                                  Set the value to `nil` to clear the existing experiment-to-variation mapping.
    #
    # @return                [Boolean] `true` if the user was successfully forced into a variation, `false` if the `experimentKey`
    #                                  isn't in the project file or the `variationKey` isn't in the experiment.

    def set_forced_variation(experiment_key, user_id, variation_key)
      @config.set_forced_variation(experiment_key, user_id, variation_key)
    end

    # Returns the forced variation set by `setForcedVariation`, or `nil` if no variation was forced.
    # A user can be forced into a variation for a given experiment for the lifetime of the Optimizely client.
    # The forced variation value is runtime only and doesn't persist across application launches.
    #
    # For more information, see https://docs.developers.optimizely.com/full-stack/docs/set-forced-variation.
    #
    # @param experiment_key [string] The key of the experiment for which to retrieve the forced variation.
    # @param user_id        [string] The ID of the user in the forced variation.
    #
    # @return               [String] The variation the user was bucketed into, or `nil` if `set_forced_variation`
    #                                failed to force the user into the variation.

    def get_forced_variation(experiment_key, user_id)
      forced_variation_key = nil
      forced_variation = @config.get_forced_variation(experiment_key, user_id)
      forced_variation_key = forced_variation['key'] if forced_variation

      forced_variation_key
    end

    # Tracks a conversion event for a user whose attributes meet the audience conditions for an experiment. 
    # When the user does not meet those conditions, events are not tracked.
    #
    # This method takes into account the user `attributes` passed in, to determine if the user is part of the audience that qualifies for the experiment.
    #
    # This method sends conversion data to Optimizely but doesn't return any values. 
    #
    # For more information, see https://docs.developers.optimizely.com/full-stack/docs/track.
    #
    # @param event_key  [string] The key of the event to be tracked. This key must match the event key provided when the event was created in the Optimizely app.
    # @param user_id    [string] The ID of the user associated with the event being tracked. This ID must match the user ID provided to `activate` or `is_feature_enabled`.
    # @param attributes [map]    A map of custom key-value string pairs specifying attributes for the user.
    # @param event_tags [map]    A map of key-value string pairs specifying event names and their corresponding event values associated with the event.

    def track(event_key, user_id, attributes = nil, event_tags = nil)
      unless @is_valid
        @logger.log(Logger::ERROR, InvalidDatafileError.new('track').message)
        return nil
      end

      return nil unless Optimizely::Helpers::Validator.inputs_valid?(
        {
          event_key: event_key,
          user_id: user_id
        }, @logger, Logger::ERROR
      )

      return nil unless user_inputs_valid?(attributes, event_tags)

      experiment_ids = @config.get_experiment_ids_for_event(event_key)
      if experiment_ids.empty?
        @config.logger.log(Logger::INFO, "Not tracking user '#{user_id}'.")
        return nil
      end

      # Filter out experiments that are not running or that do not include the user in audience conditions.

      experiment_variation_map = get_valid_experiments_for_event(event_key, user_id, attributes)

      # Don't track events without valid experiments attached.
      if experiment_variation_map.empty?
        @logger.log(Logger::INFO, "There are no valid experiments for event '#{event_key}' to track.")
        return nil
      end

      conversion_event = @event_builder.create_conversion_event(event_key, user_id, attributes,
                                                                event_tags, experiment_variation_map)
      @logger.log(Logger::INFO,
                  "Dispatching conversion event to URL #{conversion_event.url} with params #{conversion_event.params}.")
      begin
        @event_dispatcher.dispatch_event(conversion_event)
      rescue => e
        @logger.log(Logger::ERROR, "Unable to dispatch conversion event. Error: #{e}")
      end

      @notification_center.send_notifications(
        NotificationCenter::NOTIFICATION_TYPES[:TRACK],
        event_key, user_id, attributes, event_tags, conversion_event
      )
      nil
    end

    # Determines whether a feature test or rollout is enabled for a given user, and
    # sends an impression event if the user is bucketed into an experiment using the feature.
    #
    # For more information, see https://docs.developers.optimizely.com/full-stack/docs/is-feature-enabled.
    #
    # @param feature_flag_key [string]  The key of the feature to check. 
    # @param user_id          [string]  The ID of the user to check. 
    # @param attributes       [map]     A map of custom key-value string pairs specifying attributes for the user.
    #
    # @return                 [boolean] `true` if the feature is enabled, or `false` if the feature is disabled or couldn't be found.

    def is_feature_enabled(feature_flag_key, user_id, attributes = nil)
      unless @is_valid
        @logger.log(Logger::ERROR, InvalidDatafileError.new('is_feature_enabled').message)
        return false
      end

      return false unless Optimizely::Helpers::Validator.inputs_valid?(
        {
          feature_flag_key: feature_flag_key,
          user_id: user_id
        }, @logger, Logger::ERROR
      )

      return false unless user_inputs_valid?(attributes)

      feature_flag = @config.get_feature_flag_from_key(feature_flag_key)
      unless feature_flag
        @logger.log(Logger::ERROR, "No feature flag was found for key '#{feature_flag_key}'.")
        return false
      end

      decision = @decision_service.get_variation_for_feature(feature_flag, user_id, attributes)
      if decision.nil?
        @logger.log(Logger::INFO,
                    "Feature '#{feature_flag_key}' is not enabled for user '#{user_id}'.")
        return false
      end

      variation = decision['variation']
      if decision.source == Optimizely::DecisionService::DECISION_SOURCE_EXPERIMENT
        # Send event if Decision came from an experiment.
        send_impression(decision.experiment, variation['key'], user_id, attributes)
      else
        @logger.log(Logger::DEBUG,
                    "The user '#{user_id}' is not being experimented on in feature '#{feature_flag_key}'.")
      end

      if variation['featureEnabled'] == true
        @logger.log(Logger::INFO,
                    "Feature '#{feature_flag_key}' is enabled for user '#{user_id}'.")
        return true
      else
        @logger.log(Logger::INFO,
                    "Feature '#{feature_flag_key}' is not enabled for user '#{user_id}'.")
        return false
      end
    end

    # Retrieves a list of features that are enabled for the user.
    # Invoking this method is equivalent to running `is_feature_enabled` for each feature in the datafile sequentially.
    #
    # This method takes into account the user `attributes` passed in, to determine if the user
    # is part of the audience that qualifies for the experiment.    
    # 
    # For more information, see https://docs.developers.optimizely.com/full-stack/docs/get-enabled-features.
    #
    # @param user_id    [string]             The ID of the user who may have features enabled in one or more experiments.
    # @param attributes [map]                A map of custom key-value string pairs specifying attributes for the user. 
    # @return           [feature flag keys]  A list of keys corresponding to the features that are enabled for the user, 
    #                                        or an empty list if no features could be found for the specified user.

    def get_enabled_features(user_id, attributes = nil)
      enabled_features = []

      unless @is_valid
        @logger.log(Logger::ERROR, InvalidDatafileError.new('get_enabled_features').message)
        return enabled_features
      end

      return enabled_features unless Optimizely::Helpers::Validator.inputs_valid?(
        {
          user_id: user_id
        }, @logger, Logger::ERROR
      )

      return enabled_features unless user_inputs_valid?(attributes)

      @config.feature_flags.each do |feature|
        enabled_features.push(feature['key']) if is_feature_enabled(
          feature['key'],
          user_id,
          attributes
        ) == true
      end
      enabled_features
    end

    # Evaluates the specified string feature variable and returns its value.
    #
    # This method takes into account the user `attributes` passed in, to determine if the user
    # is part of the audience that qualifies for the experiment.   
    #
    # For more information, see https://docs.developers.optimizely.com/full-stack/docs/get-feature-variable.
    #
    # @param feature_flag_key [string] The key of the feature whose variable's value is being accessed.
    # @param variable_key     [string] The key of the variable whose value is being accessed.
    # @param user_id          [string] The ID of the participant in the experiment.
    # @param attributes       [map]    A map of custom key-value string pairs specifying attributes for the user. 
    #
    # @return                 [String] The value of the variable, or `nil` if the feature key is invalid, the variable key is
    #                                  invalid, or there is a mismatch with the type of the variable.

    def get_feature_variable_string(feature_flag_key, variable_key, user_id, attributes = nil)
      unless @is_valid
        @logger.log(Logger::ERROR, InvalidDatafileError.new('get_feature_variable_string').message)
        return nil
      end

      variable_value = get_feature_variable_for_type(
        feature_flag_key,
        variable_key,
        Optimizely::Helpers::Constants::VARIABLE_TYPES['STRING'],
        user_id,
        attributes
      )

      variable_value
    end

    # Evaluates the specified boolean feature variable and returns its value.
    #
    # This method takes into account the user `attributes` passed in, to determine if the user
    # is part of the audience that qualifies for the experiment.
    # 
    # For more information, see https://docs.developers.optimizely.com/full-stack/docs/get-feature-variable.
    #
    # @param feature_flag_key [string]  The key of the feature whose variable's value is being accessed.
    # @param variable_key     [string]  The key of the variable whose value is being accessed.
    # @param user_id          [string]  The ID of the participant in the experiment.
    # @param attributes       [map]     A map of custom key-value string pairs specifying attributes for the user. 
    #
    # @return                 [boolean] The value of the variable, or `nil` if the feature key is invalid, the variable key is
    #                                   invalid, or there is a mismatch with the type of the variable.

    def get_feature_variable_boolean(feature_flag_key, variable_key, user_id, attributes = nil)
      unless @is_valid
        @logger.log(Logger::ERROR, InvalidDatafileError.new('get_feature_variable_boolean').message)
        return nil
      end

      variable_value = get_feature_variable_for_type(
        feature_flag_key,
        variable_key,
        Optimizely::Helpers::Constants::VARIABLE_TYPES['BOOLEAN'],
        user_id,
        attributes
      )

      variable_value
    end

    # Evaluates the specified double feature variable and returns its value.
    #
    # This method takes into account the user `attributes` passed in, to determine if the user
    # is part of the audience that qualifies for the experiment.
    # 
    # For more information, see https://docs.developers.optimizely.com/full-stack/docs/get-feature-variable.
    #
    # @param feature_flag_key [string]  The key of the feature whose variable's value is being accessed.
    # @param variable_key     [string]  The key of the variable whose value is being accessed.
    # @param user_id          [string]  The ID of the participant in the experiment.
    # @param attributes       [map]     A map of custom key-value string pairs specifying attributes for the user. 
    #
    # @return                 [double]  The value of the variable, or `nil` if the feature key is invalid, the variable key is
    #                                   invalid, or there is a mismatch with the type of the variable.

    def get_feature_variable_double(feature_flag_key, variable_key, user_id, attributes = nil)
      unless @is_valid
        @logger.log(Logger::ERROR, InvalidDatafileError.new('get_feature_variable_double').message)
        return nil
      end

      variable_value = get_feature_variable_for_type(
        feature_flag_key,
        variable_key,
        Optimizely::Helpers::Constants::VARIABLE_TYPES['DOUBLE'],
        user_id,
        attributes
      )

      variable_value
    end

    # Evaluates the specified integer feature variable and returns its value.
    #
    # This method takes into account the user `attributes` passed in, to determine if the user
    # is part of the audience that qualifies for the experiment.
    # 
    # For more information, see https://docs.developers.optimizely.com/full-stack/docs/get-feature-variable.
    #
    # @param feature_flag_key [string]  The key of the feature whose variable's value is being accessed.
    # @param variable_key     [string]  The key of the variable whose value is being accessed.
    # @param user_id          [string]  The ID of the participant in the experiment.
    # @param attributes       [map]     A map of custom key-value string pairs specifying attributes for the user. 
    #
    # @return                 [double]  The value of the variable, or `nil` if the feature key is invalid, the variable key is
    #                                   invalid, or there is a mismatch with the type of the variable.

    def get_feature_variable_integer(feature_flag_key, variable_key, user_id, attributes = nil)
      unless @is_valid
        @logger.log(Logger::ERROR, InvalidDatafileError.new('get_feature_variable_integer').message)
        return nil
      end
      variable_value = get_feature_variable_for_type(
        feature_flag_key,
        variable_key,
        Optimizely::Helpers::Constants::VARIABLE_TYPES['INTEGER'],
        user_id,
        attributes
      )

      variable_value
    end

    private

    def get_feature_variable_for_type(feature_flag_key, variable_key, variable_type, user_id, attributes = nil)
      # Get the variable value for the given feature variable and cast it to the specified type
      # The default value is returned if the feature flag is not enabled for the user.
      #
      # feature_flag_key - String key of feature flag the variable belongs to.
      # variable_key -     String key of the variable for which we are getting the string value.
      # variable_type -    String requested type for feature variable.
      # user_id -          String user ID.
      # attributes -       Hash representing visitor attributes and values which need to be recorded.
      #
      # Returns the type-casted variable value.
      # Returns nil if the feature flag or variable or user ID is empty
      #             in case of variable type mismatch

      return nil unless Optimizely::Helpers::Validator.inputs_valid?(
        {
          feature_flag_key: feature_flag_key,
          variable_key: variable_key,
          user_id: user_id,
          variable_type: variable_type
        },
        @logger, Logger::ERROR
      )

      return nil unless user_inputs_valid?(attributes)

      feature_flag = @config.get_feature_flag_from_key(feature_flag_key)
      unless feature_flag
        @logger.log(Logger::INFO, "No feature flag was found for key '#{feature_flag_key}'.")
        return nil
      end

      variable = @config.get_feature_variable(feature_flag, variable_key)

      # Error message logged in ProjectConfig- get_feature_flag_from_key
      return nil if variable.nil?

      # Returns nil if type differs
      if variable['type'] != variable_type
        @logger.log(Logger::WARN,
                    "Requested variable as type '#{variable_type}' but variable '#{variable_key}' is of type '#{variable['type']}'.")
        return nil
      else
        decision = @decision_service.get_variation_for_feature(feature_flag, user_id, attributes)
        variable_value = variable['defaultValue']
        if decision
          variation = decision['variation']
          variation_variable_usages = @config.variation_id_to_variable_usage_map[variation['id']]
          variable_id = variable['id']
          if variation_variable_usages&.key?(variable_id)
            variable_value = variation_variable_usages[variable_id]['value']
            @logger.log(Logger::INFO,
                        "Got variable value '#{variable_value}' for variable '#{variable_key}' of feature flag '#{feature_flag_key}'.")
          else
            @logger.log(Logger::DEBUG,
                        "Variable '#{variable_key}' is not used in variation '#{variation['key']}'. Returning the default variable value '#{variable_value}'.")
          end
        else
          @logger.log(Logger::INFO,
                      "User '#{user_id}' was not bucketed into any variation for feature flag '#{feature_flag_key}'. Returning the default variable value '#{variable_value}'.")
        end
      end

      variable_value = Helpers::VariableType.cast_value_to_type(variable_value, variable_type, @logger)

      variable_value
    end

    def get_valid_experiments_for_event(event_key, user_id, attributes)
      # Get the experiments that we should be tracking for the given event.
      #
      # event_key -  Event key representing the event which needs to be recorded.
      # user_id -    String ID for user.
      # attributes - Map of attributes of the user.
      #
      # Returns Map where each object contains the ID of the experiment to track and the ID of the variation the user
      # is bucketed into.

      valid_experiments = {}
      experiment_ids = @config.get_experiment_ids_for_event(event_key)
      experiment_ids.each do |experiment_id|
        experiment_key = @config.get_experiment_key(experiment_id)
        variation_key = get_variation(experiment_key, user_id, attributes)

        if variation_key.nil?
          @logger.log(Logger::INFO, "Not tracking user '#{user_id}' for experiment '#{experiment_key}'.")
          next
        end

        variation_id = @config.get_variation_id_from_key(experiment_key, variation_key)
        valid_experiments[experiment_id] = variation_id
      end

      valid_experiments
    end

    def user_inputs_valid?(attributes = nil, event_tags = nil)
      # Helper method to validate user inputs.
      #
      # attributes - Dict representing user attributes.
      # event_tags - Dict representing metadata associated with an event.
      #
      # Returns boolean True if inputs are valid. False otherwise.

      return false if !attributes.nil? && !attributes_valid?(attributes)

      return false if !event_tags.nil? && !event_tags_valid?(event_tags)

      true
    end

    def attributes_valid?(attributes)
      unless Helpers::Validator.attributes_valid?(attributes)
        @logger.log(Logger::ERROR, 'Provided attributes are in an invalid format.')
        @error_handler.handle_error(InvalidAttributeFormatError)
        return false
      end
      true
    end

    def event_tags_valid?(event_tags)
      unless Helpers::Validator.event_tags_valid?(event_tags)
        @logger.log(Logger::ERROR, 'Provided event tags are in an invalid format.')
        @error_handler.handle_error(InvalidEventTagFormatError)
        return false
      end
      true
    end

    def validate_instantiation_options(datafile, skip_json_validation)
      unless skip_json_validation
        raise InvalidInputError, 'datafile' unless Helpers::Validator.datafile_valid?(datafile)
      end

      raise InvalidInputError, 'logger' unless Helpers::Validator.logger_valid?(@logger)
      raise InvalidInputError, 'error_handler' unless Helpers::Validator.error_handler_valid?(@error_handler)
      raise InvalidInputError, 'event_dispatcher' unless Helpers::Validator.event_dispatcher_valid?(@event_dispatcher)
    end

    def send_impression(experiment, variation_key, user_id, attributes = nil)
      experiment_key = experiment['key']
      variation_id = @config.get_variation_id_from_key(experiment_key, variation_key)
      impression_event = @event_builder.create_impression_event(experiment, variation_id, user_id, attributes)
      @logger.log(Logger::INFO,
                  "Dispatching impression event to URL #{impression_event.url} with params #{impression_event.params}.")
      begin
        @event_dispatcher.dispatch_event(impression_event)
      rescue => e
        @logger.log(Logger::ERROR, "Unable to dispatch impression event. Error: #{e}")
      end
      variation = @config.get_variation_from_id(experiment_key, variation_id)
      @notification_center.send_notifications(
        NotificationCenter::NOTIFICATION_TYPES[:ACTIVATE],
        experiment, user_id, attributes, variation, impression_event
      )
    end
  end
end
