require 'fishbowl'

module SpreeFishbowl

  class Client
    include ActiveSupport::Callbacks

    define_callbacks :request

    attr_reader :hostname, :user, :password, :location_group,
      :last_error, :last_request, :last_response

    def initialize(options = nil)
      set_options(options) if options
      # initializing like a boss
      @fishbowl = nil
      @last_error = nil
      @last_request, @last_response = nil, nil
    end

    def self.from_config
      self.new({
        :hostname => Spree::Config[:fishbowl_host],
        :user => Spree::Config[:fishbowl_user],
        :password => Spree::Config[:fishbowl_password],
        :location_group => Spree::Config[:fishbowl_location_group]
      })
    end

    def set_options(options)
      [:hostname, :user, :password, :location_group].each do |o|
        instance_variable_set("@#{o}", options[o])
      end
    end

    def self.enabled?
      SpreeFishbowl.enabled?
    end

    def configured?
      self.class.enabled? && hostname.present? &&
        user.present? && password.present?
    end

    def connected?
      !!@fishbowl && @fishbowl.connected?
    end

    def connect
      return false if !configured?

      begin
        if @fishbowl
          if !@fishbowl.connected?
            @fishbowl.connect.login(user, password)
          end
        else
          @fishbowl = Fishbowl::Connection.new(:host => hostname).
                        connect.login(user, password)
        end
      rescue Exception => e
        Rails.logger.debug e
      end

      connected?
    end

    def disconnect
      @fishbowl.close if connected?
      true
    end

    def customer(name)
      execute_request(:get_customer, { :name => name }) || nil
    end

    def carriers
      execute_request(:get_carrier_list) || []
    end

    def location_groups
      execute_request(:get_location_group_list) || []
    end

    def part(sku, location_group = nil)
      execute_request(:get_part, {
        :part_num => sku,
        :location_group => location_group || @location_group
      }) || nil
    end

    def parts
      execute_request(:get_light_part_list) || []
    end

    def available_inventory(variant, location_group = nil)
      location_group = location_group || @location_group
      return nil if location_group.blank? || variant.sku.blank?

      execute_request(:get_total_inventory, {
        :part_number => variant.sku,
        :location_group => location_group
      })
    end

    def create_customer(order)
      customer_obj = CustomerAdapter.adapt(order)
      execute_request(:save_customer, { :customer => customer_obj }, order.id)
    end

    def create_sales_order(order, issue = true)
      sales_order = SalesOrderAdapter.adapt(order)
      if !sales_order.customer_name.nil?
        customer_obj = customer(sales_order.customer_name)
        create_customer(order) if !customer_obj
      end
      execute_request(:save_sales_order, { :issue => issue, :sales_order => sales_order}, order.id)
    end

    def get_order_shipments(order)
      ship_results = execute_request(:get_ship_list, {
        :order_number => order.so_number,
        :record_count => 50
      })
      ship_results.reject { |r| r.order_number != order.so_number }.
        select { |r| r.status == 'Shipped' }.
        map do |ship_result|
          execute_request(:get_shipment, { :shipment_id => ship_result.ship_id }, order.id)
        end if !ship_results.nil?
    end

  private

    def connection
      connect if !connected?
      @fishbowl
    end

    def execute_request(request_name, params = {}, order_id = nil)
      fishbowl = connection
      return nil if !connected?

      run_callbacks :request do
        begin
          @last_error = nil
          fishbowl.send(request_name, params)
        rescue Fishbowl::Errors::StatusError => e
          # nothing special at the moment
          @last_error = e
          Rails.logger.debug e
          nil
        ensure
          @last_request = fishbowl.last_request
          @last_response = fishbowl.last_response
          fishbowl.close
        end
      end
    end

  end

end