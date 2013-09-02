require 'fishbowl'

module SpreeFishbowl

  class Client

    attr_reader :hostname, :port, :user, :password, :location_group,
      :last_error, :last_request, :last_response

    def initialize(options = nil)
      @max_retries = options[:max_retries] || 1
      set_options(options) if options
      # initializing like a boss
      @fishbowl = nil
      @last_error = nil
      @last_request, @last_response = nil, nil
      @auto_close = true
    end

    def self.from_config(addl_options = {})
      self.new({
        :hostname => Spree::Config[:fishbowl_host],
        :port => Spree::Config[:fishbowl_port],
        :user => Spree::Config[:fishbowl_user],
        :password => Spree::Config[:fishbowl_password],
        :location_group => Spree::Config[:fishbowl_location_group]
      }.merge(addl_options))
    end

    def set_options(options)
      [:hostname, :port, :user, :password, :location_group].each do |o|
        instance_variable_set("@#{o}", options[o])
      end
    end

    # You MUST manually close the connection if you disable
    # auto-close
    def set_auto_close(do_auto_close = true)
      @auto_close = do_auto_close
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

    def error?
      !!@last_error
    end

    def error
      @last_error
    end

    def connect
      return false if !configured?

      begin
        if @fishbowl
          if !@fishbowl.connected?
            @fishbowl.connect.login(user, password)
          end
        else
          @fishbowl = Fishbowl::Connection.new(:host => hostname, :port => port).
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

    def reconnect
      disconnect && connect
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

    def product(sku)
      execute_request(:get_product, {
        :product_num => sku
      }) || nil
    end

    def parts
      execute_request(:get_light_part_list) || []
    end

    def available_inventory(variant, location_group = nil)
      location_group = location_group || @location_group
      return nil if variant.sku.blank?

      fb_product = product(variant.sku)

      inventory_counts = execute_request(:get_inventory_quantity, {
          :part_number => fb_product.part.num
        }) unless fb_product.nil?
      inventory_counts.qty_available if inventory_counts
    end

    def all_available_inventory
      # This is inefficient, but constructing this in a single
      # Arel query will take a bit of time
      Spree::Variant.all.reject do |variant|
        variant.sku.blank? || (
          variant.is_master? && variant.product.has_variants?
        )
      end.each do |variant|
        inventory = available_inventory(variant)
        yield [variant, inventory] if block_given?
        [variant, inventory]
      end
    end

    def create_customer(order)
      customer_obj = CustomerAdapter.adapt(order)
      execute_request(:save_customer, { :customer => customer_obj }, order.id)
    end

    def create_sales_order(order, issue = true)
      sales_order = SalesOrderAdapter.adapt(order)
      if sales_order.customer_name.present?
        customer_obj = customer(sales_order.customer_name)
        if !customer_obj
          create_customer(order)
          # customer creation doesn't return a value, so we
          # need to check if an error was set
          return nil if error?
        end
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

      failure_count = 0

      begin
        @last_error = nil
        fishbowl.send(request_name, params)
      rescue Fishbowl::Errors::ServerError => e
        Rails.logger.debug e
        # Attempt call up to three times
        unless ((failure_count += 1) <= @max_retries && reconnect)
          log_error e
          return nil
        end
        retry
      rescue Fishbowl::Errors::StatusError => e
        # Nothing special at the moment
        log_error e
        return nil
      ensure
        @last_request = fishbowl.last_request
        @last_response = fishbowl.last_response
        fishbowl.close if @auto_close
      end
    end

    def log_error(e)
      @last_error = e
      Rails.logger.debug e
    end

  end

end
