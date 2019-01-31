module Spree
  module Manage
    class OrdersController < Spree::Manage::BaseController

      helper_method :sort_column, :sort_direction
      respond_to :js

      before_action :clear_current_order, only: [:index, :new]
      before_action :ensure_vendor, only: [:show, :edit, :update, :destroy, :void, :mark_paid, :mark_unpaid, :get_lot_qty]
      before_action :ensure_editable, only: :update
      before_action :ensure_read_permission, only: [:new, :create, :update, :edit, :show, :index, :destroy, :add_line_item]

      after_action :send_invoice, only: :update, if: -> {@send_as_invoice}
      # before_action :load_data
      # before_action :load_payment, except: [:create, :new, :index]
      # before_action :load_order, only: [:create, :new, :index]

      def index
        params[:q] ||= {}
        @vendor = current_vendor
        @customers = @vendor.customers.order('name ASC')
        order_hash = current_spree_user.permissions.fetch('order')
        @manual_adjustment = order_hash.fetch('manual_adjustment')
        @default_statuses = %w{cart complete approved shipped review invoice}
        @order_limit = @vendor.subscription_limit('order_history_limit')
        params[:q][:shipment_state_or_state_cont_any] = @default_statuses if params[:q][:shipment_state_or_state_cont_any].blank?

        format_ransack_date_field(:delivery_date_gteq, @vendor)
        format_ransack_date_field(:delivery_date_lteq, @vendor)
        format_ransack_date_field(:invoice_date_gteq, @vendor)
        format_ransack_date_field(:invoice_date_lteq, @vendor)
        format_ransack_date_field(:completed_at_gteq, @vendor)
        format_ransack_date_field(:completed_at_lteq, @vendor)

        if params[:q] && params[:q][:shipment_state_or_state_cont_any].include?('cart')
          params[:q][:created_at_lteq], params[:q][:created_at_gteq] = params[:q][:completed_at_lteq], params[:q][:completed_at_gteq]
          params[:q][:completed_at_lteq], params[:q][:completed_at_gteq] = nil, nil

          # Last order which is not carted or deleted
          if @order_limit
            params[:q][:created_at_gteq] = @vendor.sales_orders.where.not(state:['cart','canceled']).order('created_at desc').limit(@order_limit).last.try(:created_at)
          end

          params[:q][:completed_at_lteq], params[:q][:completed_at_gteq] = params[:q][:created_at_lteq], params[:q][:created_at_gteq]
          params[:q][:created_at_lteq], params[:q][:created_at_gteq] = nil, nil

        else
          params[:q][:created_at_gteq] = @vendor.sales_orders.where.not(state:['cart','canceled']).order('created_at desc').limit(@order_limit).last.try(:created_at)

          if @order_limit
            params[:q][:created_at_gteq] = @vendor.sales_orders.where.not(state:['cart','canceled']).order('created_at desc').limit(@order_limit).last.try(:created_at)
          end
        end

        @any_orders_today = @vendor.sales_orders.where(state: InvoiceableStates, delivery_date: overview_date_t).exists?
        @any_approved_orders_today = @vendor.sales_orders.approved.where(delivery_date: overview_date_t).exists?
        @search = @vendor.sales_orders.order('completed_at DESC').ransack(params[:q])
        respond_to do |format|
          format.html
          format.json { render json: SpreeOrderDatatable.new(view_context, vendor: current_vendor, user: current_spree_user, ransack_params: params[:q])}
        end

        revert_ransack_date_to_view(:delivery_date_gteq, @vendor)
        revert_ransack_date_to_view(:delivery_date_lteq, @vendor)
        revert_ransack_date_to_view(:invoice_date_gteq, @vendor)
        revert_ransack_date_to_view(:invoice_date_lteq, @vendor)
        revert_ransack_date_to_view(:completed_at_gteq, @vendor)
        revert_ransack_date_to_view(:completed_at_lteq, @vendor)
      end

      def new
        @vendor = current_vendor
        if @vendor.selectable_delivery
          date = Time.current.in_time_zone(@vendor.time_zone).to_date + 1.day
        else
          date = Time.current.in_time_zone(@vendor.time_zone).to_date
        end
        @order = @vendor.sales_orders.new(delivery_date: date, due_date: date, invoice_date: date)
        @search = @order.line_items.ransack(params[:q])
        @line_items = @search.result.page(params[:page])

        @customer_accounts = @vendor.customer_accounts.active.order('fully_qualified_name ASC')
        @days_available = nil
        render :new
      end

      def create
        @vendor = current_vendor
        @account = @vendor.customer_accounts.find_by_id(order_params.fetch(:account_id, nil))
        if @account && !@account.can_select_delivery? && params[:order] && params[:order][:delivery_date].blank?
          params[:order][:delivery_date] = DateHelper.sweet_today(@vendor.try(:time_zone)).in_time_zone('UTC')
        else
          format_form_date_field(:order, :delivery_date, @vendor)
        end
        if params[:order] && params[:order][:due_date].blank?
          params[:order][:due_date] = params[:order][:delivery_date] + @account.try(:payment_days).to_i.days rescue nil
        else
          format_form_date_field(:order, :due_date, @vendor)
        end
        if order_params[:account_id].present?
          @order = @vendor.sales_orders.where('spree_orders.account_id = ? AND spree_orders.id NOT IN (SELECT spree_line_items.order_id FROM spree_line_items)', order_params[:account_id]).first
          if @order #resets the order
            now = Time.current
            @order.update_columns(created_at: now,
                                  updated_at: now,
                                  user_id: nil,
                                  invoice_date: params[:order][:delivery_date],
                                  due_date: params[:order][:due_date])
          end
          @order ||= @vendor.sales_orders.new(order_params)
          @search = @order.line_items.ransack(params[:q])
          @line_items = @search.result.page(params[:page])
          @customer_accounts = @vendor.customer_accounts.active.order('fully_qualified_name ASC')
          associate_user(@order)
          @order.account_id = order_params[:account_id].to_i
          @order.txn_class_id = @account.try(:default_txn_class_id) if @order.vendor.track_order_class?
          @days_available = generate_days(@order.account)
          @order.set_shipping_method
          @users = @account.users.where(company_id: @order.account.customer_id).order('lastname asc') if @order.account
          if (@order.persisted? && @order.update(order_params)) || (!@order.persisted? && @order.save)
            set_order_session(@order)

            respond_with(@order) do |format|
              format.html do
                flash[:success] = "You've started a new order!"
                redirect_to edit_manage_order_path(@order)
              end
              format.js {}
            end
          else
            respond_with(@order) do |format|
              format.html do
                flash.now[:errors] = @order.errors.full_messages
                render :new
              end
              format.js do
                flash.now[:errors] = @order.errors.full_messages
              end
            end
          end
        else
          respond_with(@order) do |format|
            format.html do
              flash.now[:error] = "Please select an account"
              render :new
            end
            format.js do
              flash.now[:error] = "Please select an account"
            end
          end
        end
      end

      def show
        redirect_to edit_manage_order_url(params[:id])
      end

      def customer_accounts
        if params[:order_number].present?
          @order = current_vendor.sales_orders.find_by_number(params[:order_number])
        end
        @account_id = params[:account_id]

        @customer_account = current_vendor.customer_accounts.find(@account_id)
        @account_address_ship = @customer_account.shipping_addresses.first
        @account_address_bill = @customer_account.billing_addresses.first
        if @order && @customer_account
          @order.update_columns(
            account_id: @account_id,
            ship_address_id: @account_address_ship.try(:id),
            bill_address_id: @account_address_bill.try(:id),
            email: @order.set_email(@customer_account),
            user_id: @customer_account.users.first.try(:id),
            due_date: @order.set_due_date(@customer_account)
          )
        end
        @customer = @customer_account.customer
        @days_available = generate_days(@customer_account)
        @date_selected = params[:date_selected]
        @next_available_day = get_num_until_next_available_day(@days_available)[0]
        respond_to do |format|
         format.js do
            @account_id
            @customer_account
            @customer
            @days_available
            @vendor = current_vendor
            @next_available_day = @date_selected == 'true' ? nil : @next_available_day
            @account_address
            @users = @customer_account.users.where(company_id: @customer_account.customer_id).order('lastname asc')
            @date_selected
          end
        end
      end

      def edit
        @order = set_order_session
        @days_available = generate_days(@order.account)
        @customer = @order.customer
        @vendor = current_vendor
        @search = @order.line_items.select('spree_line_items.*, (price - price_discount) as discount_price, (quantity * (price - price_discount)) as amount').includes(:inventory_units, variant: :product).ransack(params[:q])
        @search.sorts = @vendor.cva.try(:line_item_default_sort) if @search.sorts.empty?
        @line_items = @search.result.includes(line_item_lots: :lot)
        @variants = @vendor.variants_including_master.includes(:product, :option_values)
        @payments = @order.payments.includes(refunds: :reason)
        @refunds = @payments.flat_map(&:refunds)
        if @order.thread.comments.exists?
          commontator_thread_show(@order)
        end
        render :edit
      end

      def update_order_line_items_position
        params[:order].each do |key,value|
          Spree::LineItem.find(value[:id]).update_attribute(:position, value[:position])
        end
        render :nothing => true
      end

      def update
        @vendor = current_vendor
        @order = @vendor.sales_orders.includes(:line_items, shipments: :inventory_units).friendly.find(params[:id])
        @days_available = generate_days(@order.account)
        @customer = @order.customer
        @search = @order.line_items.includes(:inventory_units, variant: :product).ransack(params[:q])
        @search.sorts = @vendor.cva.try(:line_item_default_sort) if @search.sorts.empty?
        @line_items = @search.result.includes(line_item_lots: :lot)
        @variants = @vendor.variants_including_master.includes(:product, :option_values)
        @payments = @order.payments.includes(refunds: :reason)
        @refunds = @payments.flat_map(&:refunds)

        format_form_date_field(:order, :due_date, @vendor)
        format_form_date_field(:order, :delivery_date, @vendor)
        if format_form_date_field(:order, :invoice_date, @vendor) == @order.created_at.to_date
          params[:order][:invoice_date] = @order.created_at
        end
        #only setting this if it is left blank, not if the param is not sent at all
        if params[:order] && params[:order][:shipment_total] == ''
          params[:order][:shipment_total] = 0.0
        end
        errors = @order.create_shipment! if @order.shipments.none?
        if params[:commit].to_s.downcase.include?('invoice')
          @send_as_invoice = true
          params[:order][:invoiced_at] = Time.current.to_s
        end
        if @order.update(order_params)
          @order.item_count = @order.quantity
          @order.persist_totals
          case params[:commit]
          when Spree.t(:add_item)
            handle_success_render(manage_products_path)
          when Spree.t(:submit)
            if @order.is_valid?
              @order.next
              flash[:success] = "Order ##{@order.display_number} submitted"
              handle_success_render(manage_orders_path)
            else
              flash.now[:errors] = @order.errors_including_line_items.reject(&:blank?)
              render :edit
            end
          when Spree.t('order.actions.approve'), Spree.t('order.actions.approve_and_invoice')
            errors = @order.approve(current_spree_user)
            @recently_approved = true
            if errors.blank?
              flash[:success] = "Order Approved!"
              handle_success_render(manage_orders_path)
            else
              respond_to do |format|
                format.html do
                  flash.now[:errors] = errors
                  render :edit
                end
                format.js do
                  flash[:errors] = errors
                  render js: "window.location.href = '" + edit_manage_order_path(@order) + "'"
                end
              end
            end
          when Spree.t('order.actions.ship'), Spree.t('order.actions.ship_and_invoice')
            @recently_approved = true
            # lot_match = @order.all_ordered_quantities(order_params[:line_items_attributes]) == @order.lot_sums_in_array
            # valid_lots = @vendor.lot_tracking ? lot_match : true
            if @order.inventory_units.where(state: 'backordered').present?
              flash.now[:errors] = ['Some items in your order are backordered.  Please add stock before shipping']
              render :edit
            elsif @order.shipments.none?
              flash.now[:errors] = ['No shipment found. Please check that there are shipping methods set up. Contact help@onsweet.co for further assistance.']
              render :edit
            elsif @order.is_valid? && @order.validate_lot_counts && @order.validate_lots_can_sell
              @order.line_items.each do |line_item|
                line_item.shipped_qty = line_item.quantity
              end
              if @order.override_shipment_cost
                @order.shipments.each do |s|
                  s.refresh_rates
                  s.update_amounts
                end
              end
              @order.next
              flash[:success] = "Order has shipped!"
              redirect_to manage_orders_path
            else
              errors = @order.errors_including_line_items
              flash.now[:errors] = errors.reject(&:blank?)
              # flash.now[:errors] << 'Lot quantites do not equal ordered quantities' unless lot_match
              render :edit
            end
          when Spree.t('order.actions.confirm_delivered')
            flash[:success] = "Order has been delivered!"
            if @order.is_valid?
              @order.next
              @order.shipments.each {|s| s.receive}
              redirect_to manage_orders_path
            else
              errors = @order.errors_including_line_items
              flash.now[:errors] = errors.reject(&:blank?)
              render :edit
            end
          when Spree.t('order.actions.finalize'), Spree.t('order.actions.finalize_and_invoice')
            @order.next
            flash[:success] = "Order has been finalized!"
            redirect_to manage_orders_path
          else
            if States[@order.state] > States['approved']
              @order.trigger_transition
            end
            flash[:success] = "Your order has been successfully updated!"
            handle_success_render(edit_manage_order_path(@order))
          end

          @order.shipments.each do |s|
            s.refresh_rates
            s.update_amounts
          end
          unless @order.contents.update_cart({order_state: @order.state})
            @order.item_count = @order.quantity
            @order.persist_totals
            Spree::OrderUpdater.new(@order).update
          end

          # don't do if just approved above
          if @order.state == 'approved' && !@recently_approved
            @order.back_to_complete
            if @order.errors.empty?
              @order.approve(current_spree_user)
            else
              flash[:error] = @order.errors.full_messages
            end
          end

        else
          flash[:success] = nil
          flash.now[:errors] = @order.errors.full_messages
          render :edit
        end
      end

      def handle_success_render(redirect_path)
        respond_with(@order) do |format|
          format.js do
            render js: "window.location.href = '" + redirect_path + "'"
          end
          format.html do
            redirect_to redirect_path
          end
        end
      end

      def get_num_until_next_available_day(days_available)
        blackout_days = days_available[0]
        if blackout_days != "0,1,2,3,4,5,6"
          next_available_day = Time.now.to_date + 1
          counter = 1
          while(blackout_days.include? next_available_day.wday.to_s)
            next_available_day += 1
            counter += 1
          end
          return counter.to_s + "d", next_available_day
        else
          return nil, nil
        end
      end

      def generate_days(account)
        @account = account
        days_to_blackout = ""
        day_tracker = []
        available_days = "Delivery to this customer is only on "
        deliverable_days = @account.deliverable_days
        if deliverable_days["0"] && deliverable_days["6"] && !deliverable_days["1"] && !deliverable_days["2"] && !deliverable_days["3"] && !deliverable_days["4"] && !deliverable_days["5"]
          available_days = "Delivery to this customer is only on weekends"
          days_to_blackout = "1,2,3,4,5"
        elsif !deliverable_days["0"] && !deliverable_days["6"] && deliverable_days["1"] && deliverable_days["2"] && deliverable_days["3"] && deliverable_days["4"] && deliverable_days["5"]
          available_days = "Delivery to this customer is only on weekdays"
          days_to_blackout = "0,6"
        elsif !deliverable_days["0"] && !deliverable_days["6"] && !deliverable_days["1"] && !deliverable_days["2"] && !deliverable_days["3"] && !deliverable_days["4"] && !deliverable_days["5"]
          available_days = "There is no delivery to this customer"
          days_to_blackout = "0,1,2,3,4,5,6"
        elsif deliverable_days["0"] && deliverable_days["6"] && deliverable_days["1"] && deliverable_days["2"] && deliverable_days["3"] && deliverable_days["4"] && deliverable_days["5"]
          available_days = "Vendor delivers every day"
          days_to_blackout = ""
        else
          @account.delivery_on_sunday ? day_tracker.push('Sundays') : days_to_blackout += '0,'
          @account.delivery_on_monday ? day_tracker.push('Mondays') : days_to_blackout += '1,'
          @account.delivery_on_tuesday ? day_tracker.push('Tuesdays') : days_to_blackout += '2,'
          @account.delivery_on_wednesday ? day_tracker.push('Wednesdays') : days_to_blackout += '3,'
          @account.delivery_on_thursday ? day_tracker.push('Thursdays') : days_to_blackout += '4,'
          @account.delivery_on_friday ? day_tracker.push('Fridays') : days_to_blackout += '5,'
          @account.delivery_on_saturday ? day_tracker.push('Saturdays') : days_to_blackout += '6,'

          available_days += day_tracker.to_sentence

        end

        return days_to_blackout, available_days
      end

      def add_to_cart
        @order = Spree::Order.includes(:line_items, :adjustments, :payments, :shipments).find_by_id(session[:order_id])
        if @order.nil?
          @order = Spree::Order.includes(:line_items, :adjustments, :payments, :shipments).friendly.find(params[:order_id]) rescue nil
          session[:order_id] = @order.try(:id)
        end
        errors = ["Could not find order in your current session. Try selecting the order again."]

        unless @order.nil?
      		errors = []

          if params[:order] && params[:order][:products]
      			variants = params[:order][:products].keep_if do |id, qty|
      				qty.to_f.between?(0.00001, 2_147_483_647)
      			end
            errors = variants.empty? ? ["No products were selected"] : @order.contents.add_many(variants, {})
          end

          if @order.state == 'approved'
            @order.back_to_complete
            @order.approve(current_spree_user)
          end
        end


        respond_with(@order) do |format|
          if errors.present?
            format.html do
              flash[:errors] = errors
              redirect_to :back
            end
            format.js {flash.now[:errors] = errors}
          else
            format.html do
              flash[:success] = "Your order has been updated!"
              redirect_to edit_manage_order_path(@order)
            end
            format.js { flash.now[:success] = "Your order has been updated!"}
          end
        end
      end

      def actions_router
        @vendor = current_vendor
        if params[:company] && params[:company][:sales_orders_attributes]
          params[:company][:sales_orders_attributes] ||= {}
          order_ids = params[:company][:sales_orders_attributes].map {|k, v| v[:id] if v[:action] == '1'}.compact
        end

        sort = params[:sort]
        case params[:commit]
        when Spree.t('order.bulk_actions.approve')
          approve_orders(@vendor, order_ids)
        when Spree.t('order.bulk_actions.ship')
          ship_orders(@vendor, order_ids)
        when Spree.t('order.bulk_actions.receive')
          receive_orders(@vendor, order_ids)
        when Spree.t('order.bulk_actions.invoice')
          invoice_orders(@vendor, order_ids)
        when Spree.t('payment_actions.mark.paid')
          Spree::Order.mark_many_paid(@vendor, order_ids)
        when Spree.t('payment_actions.mark.unpaid')
          Spree::Order.mark_many_unpaid(@vendor, order_ids)
        when Spree.t('order.bulk_actions.pdf_packing_slips')
          redirect_to collate_packing_slips_manage_orders_path(order_ids: order_ids, sort: sort) and return
        when Spree.t('order.bulk_actions.pdf_invoices')
          redirect_to collate_selected_invoice_manage_orders_path(order_ids: order_ids, sort: sort) and return
        when Spree.t('order.bulk_actions.download_csv')
          redirect_to download_csv_manage_orders_path(order_ids: order_ids, sort: sort) and return
        when Spree.t('order.bulk_actions.download_xlsx')
          redirect_to download_xlsx_manage_orders_path(order_ids: order_ids, sort: sort) and return
        end

        redirect_to manage_orders_url
      end

      def approve_orders(vendor, order_ids)
        approved_count = 0
        errors = []
        failed_orders = []
        vendor.sales_orders.unapproved.where(id: order_ids).each do |order|
          error = order.approve(current_spree_user)
          if error.blank?
            approved_count += 1
          else
            failed_orders << order.display_number
            errors += error
          end
        end
        if approved_count > 0 && errors.empty?
          flash[:success] = "#{approved_count} #{'order'.pluralize(approved_count)} approved!"
        elsif approved_count == 0 && errors.empty?
          flash[:error] = "No unapproved orders were selected"
        else
          flash[:success] = "#{approved_count} #{'order'.pluralize(approved_count)} were approved" if approved_count > 0
          flash[:error] = "Errors occurred in the following #{'order'.pluralize(failed_orders.count)}: #{failed_orders.join(', ')}"
          flash[:errors] = errors
        end
      end

      def unapprove
        @order = Spree::Order.friendly.find(params[:order_id])
        @order.unapprove
        OrderMailer.unapprove(@order.id).deliver_later

        flash[:success] = "Unapproved Order ##{@order.display_number}"
        redirect_to edit_manage_order_path(params[:order_id])
      end

      def ship_orders(vendor, order_ids)
        shipped_count = 0
        errors = []
        failed_orders = []
        vendor.sales_orders.where(state: 'approved', id: order_ids).each do |order|
          if order.inventory_units.where(state: 'backordered').present?
            failed_orders << order.display_number
            errors << "Some items in your Order ##{order.display_number} are backordered."
          elsif !order.validate_lots_can_sell
            failed_orders << order.display_number
            errors << "Some items in you order ##{order.display_number} have lots that are passed the sell by date"
          elsif !order.validate_lot_counts
            failed_orders << order.display_number
            errors << "Some items in you order ##{order.display_number} have lot quantities that don't match the line quantity"
          elsif order.shipments.none?
            failed_orders << order.display_number
            errors << "No shipment found. Please check that there are shipping methods set up. Contact help@onsweet.co for further assistance."
          elsif order.is_valid?
            order.line_items.each {|li| li.shipped_qty = li.quantity}
            order.next
            order.shipments.each {|s| s.ship! }
            shipped_count += 1
          else
            failed_orders << order.display_number
            errors += order.errors_including_line_items
          end
        end

        if shipped_count > 0 && errors.empty?
          flash[:success] = "#{shipped_count} #{'order'.pluralize(shipped_count)} shipped."
        elsif shipped_count == 0 && errors.empty?
          flash[:error] = "No approved orders were selected"
        else
          flash[:success] = "#{shipped_count} #{'order'.pluralize(shipped_count)} shipped." if shipped_count > 0
          flash[:error] = "Errors occurred in the following #{'order'.pluralize(failed_orders.count)}: #{failed_orders.join(', ')}"
          flash[:errors] = errors
        end
      end

      def receive_orders(vendor, order_ids)
        received_count = 0
        vendor.sales_orders.where(state: 'shipped', id: order_ids).each do |order|
          order.next
          order.shipments.each {|s| s.receive }
          received_count += 1
        end

        if received_count > 0
          flash[:success] = "#{received_count} #{'order'.pluralize(received_count)} received!"
        else
          flash[:error] = "No shipped orders were selected"
        end
      end

      def invoice_orders(vendor, order_ids)
        invoice_count = 0
        invoice_ids = vendor.sales_orders.where(state: InvoiceableStates, id: order_ids).pluck(:invoice_id).uniq

        vendor.sales_invoices.where(id: invoice_ids).each do |invoice|
          invoice.send_invoice
          invoice_count += 1
        end

        if invoice_count > 0
          flash[:success] = "#{invoice_count} #{'order'.pluralize(invoice_count)} invoiced!"
        else
          flash[:error] = "Could not invoice selected orders."
        end

      end

      def collate_packing_slips(order_ids = nil, sort = 'spree_accounts.fully_qualified_name asc')
        vendor = current_vendor
        sort = params[:sort] if params[:sort].present?
        order_ids ||= params[:order_ids]
        orders = vendor.sales_orders.includes(:account, :line_items).where(id: order_ids).order(sort)

        if orders.present?
          bookkeeping_document = CombinePDF.new
          orders.each {|order| bookkeeping_document << CombinePDF.parse(order.pdf_packaging_list_for_order.pdf)}
          send_data bookkeeping_document.to_pdf, filename: "#{Time.current.in_time_zone(vendor.try(:time_zone)).strftime('%Y-%m-%d')}_packing_slips.pdf", type: 'application/pdf', disposition: 'inline'
        else
          flash[:error] = "No orders were selected"
          redirect_to manage_orders_url
        end
      end

      def collate_selected_invoice(order_ids = nil, sort = 'spree_accounts.fully_qualified_name asc')
        vendor = current_vendor
        sort = params[:sort] if params[:sort].present?
        if sort.start_with?('delivery_date')
          sort = "end_date #{sort.split(' ').last}"
        end
        order_ids ||= params[:order_ids]
        orders = vendor.sales_orders.includes(:invoice).where(id: order_ids)
        invoice_ids = orders.where.not(invoice_id: nil).pluck(:invoice_id).uniq
        invoices = Spree::Invoice.includes(:account, :orders).where(id: invoice_ids).order(sort)

        if invoices.present?
          bookkeeping_document = CombinePDF.new
          invoices.each{ |invoice|
            bookkeeping_document << CombinePDF.parse(invoice.pdf_invoice.pdf)
          }
          send_data bookkeeping_document.to_pdf, filename: "#{Time.current.in_time_zone(vendor.try(:time_zone)).strftime('%Y-%m-%d')}_invoices.pdf", type: 'application/pdf', disposition: 'inline'
        else
          flash[:error] = "Selected orders don't have an invoice"
          redirect_to manage_orders_url
        end
      end

      def download_csv(order_ids = nil, sort = 'spree_accounts.fully_qualified_name asc')
        vendor = current_vendor
        sort = params[:sort] if params[:sort].present?
        if sort.start_with?('delivery_date')
          sort = "end_date #{sort.split(' ').last}"
        end
        order_ids ||= params[:order_ids]
        if order_ids
          orders = vendor.sales_orders.includes(:account, :line_items).where(id: order_ids).order(sort)
        else
          orders = vendor.sales_orders.includes(:account, :line_items).where('delivery_date = ?', overview_date_t).order(sort)
        end
        options = {}
        if orders.present?
          send_data orders.to_csv(options), filename: "#{Time.current.in_time_zone(vendor.try(:time_zone)).strftime('%Y-%m-%d')}_orders.csv", type: 'text/csv', disposition: 'inline'
        else
          flash[:error] = "No orders selected"
          redirect_to manage_orders_url
        end
      end

      def download_xlsx(order_ids = nil, sort = 'spree_accounts.fully_qualified_name asc')
        vendor = current_vendor
        sort = params[:sort] if params[:sort].present?
        if sort.start_with?('delivery_date')
          sort = "end_date #{sort.split(' ').last}"
        end
        order_ids ||= params[:order_ids]
        if order_ids
          orders = vendor.sales_orders.includes(:account, :line_items).where(id: order_ids).order(sort)
        else
          orders = vendor.sales_orders.includes(:account, :line_items).where('delivery_date = ?', overview_date_t).order(sort)
        end
        options = {}
        if orders.present?
          send_data orders.to_xlsx(options).to_stream.read, filename: "#{Time.current.in_time_zone(vendor.try(:time_zone)).strftime('%Y-%m-%d')}_orders.xlsx", type: 'application/xlsx'
        else
          flash[:error] = "No orders selected"
          redirect_to manage_orders_url
        end
      end

      def mark_paid
        if @order.mark_paid
          flash[:success] = "Order payment state changed."
        else
          flash[:errors] = @order.errors.full_messages
        end
        respond_with(@order) do |format|
          format.js do
            render :update_payment_state
          end
        end
      end

      def mark_unpaid
        @order.mark_unpaid
        if @order.mark_unpaid
          flash[:success] = "Order payment state changed."
        else
          flash[:errors] = @order.errors.full_messages
        end
        respond_with(@order) do |format|
          format.js do
            render :update_payment_state
          end
        end
      end

      # Adds a new item to the order (creating a new order if none already exists)
      def populate
        order = current_order
        variant  = Spree::Variant.find(params[:index])
        options  = params[:options] || {}

        # 2,147,483,647 is crazy. See issue #2695.
        if quantity.to_f.between?(0.00001, 2_147_483_647)
          begin
            order.contents.add(variant, quantity, options)
          rescue ActiveRecord::RecordInvalid => e
            error = e.record.errors.full_messages.join(", ")
          end
        else
          error = Spree.t(:please_enter_reasonable_quantity)
        end

        respond_with(order) do |format|
          if error
            format.js { flash[:error] = error }
          else
            format.js { flash.now[:success] = "#{variant.product.name} has been added to your order"}
          end
        end
      end

      def unpopulate
        error = nil
        @line_item = Spree::LineItem.find_by_id(params[:line_item_id])
        order_hash = current_spree_user.permissions.fetch('order')
        @approve_ship_receive = order_hash.fetch('approve_ship_receive')
        if @line_item
          @order = @line_item.order
          @line_item.quantity = 0 #set qty to zero so inventory is restocked
          if @line_item.destroy
            @order.contents.update_cart({})
            if @order.line_items.count == 0
              @order.back_to_cart
            elsif @order.state == 'approved'
              @order.back_to_complete
              @order.approve(current_spree_user)
            end
          else
            error = "Could not remove item."
          end
        end

        respond_with(@order, @line_item) do |format|
          format.js {flash.now[:error] = error}
        end
      end

      def add_line_item
        errors = []
        begin
          @order = current_vendor.sales_orders.friendly.find(params[:id])
          @variant = current_vendor.variants_including_master.find(params[:variant_id])
          @avv = @order.account.account_viewable_variants.where(variant_id: @variant.id).first
          errors = @order.contents.add_many({params[:variant_id] => params[:variant_qty].to_f}, {})
          @line_item = @order.line_items.where(variant_id: params[:variant_id]).last
          if @order.state == 'approved'
            @order.back_to_complete
            @order.approve(current_spree_user)
          end

        rescue Exception => e
          errors = [e.message]
        end

        flash.now[:errors] = errors if errors.any?
        render :add_line_item
      end

      def variant_search
        @vendor = current_vendor
        @order = @vendor.sales_orders.friendly.find(params[:order_id]) rescue nil
        @variants = @vendor.variants_for_sale.includes(:product, :option_values).order('fully_qualified_name asc')
        respond_with(@variants)
      end

      def destroy
        @order = set_order_session
        if @order.state != "cart" && @order.canceled_by(try_spree_current_user)
          flash[:success] = "Order ##{@order.display_number} has been canceled"
          clear_current_order
        elsif @order.destroy
          clear_current_order
          flash[:success] = "Order ##{@order.display_number} has been canceled"
        else
          flash[:errors] = @order.errors.full_messages
        end
        redirect_to manage_orders_url
      end

      def resend_email
        @order = current_vendor.sales_orders.friendly.find(params[:id]) rescue nil
        flash[:success] = 'Email will be sent shortly'
        case @order.try(:state)
        when 'approved'
          Spree::OrderMailer.approved_email(@order.id, true).deliver_later
        when 'shipped'
          if @order.shipments.any?
            @order.shipments.each do |shipment|
              Spree::ShipmentMailer.shipped_email(shipment.id, true).deliver_later
            end
          else
            flash[:success] = nil
            flash[:error] = "Could not find any shipments for order ##{@order.display_number}"
          end
        when 'review'
          Spree::OrderMailer.review_order_email(@order.id, true).deliver_later
        when 'invoice'
          Spree::OrderMailer.final_invoice_email(@order.id, true).deliver_later
        when nil
          flash[:success] = nil
          flash[:error] = 'Could not find order'
        end

        respond_to do |format|
          format.js {}
        end
      end

      def send_invoice
        @order = current_vendor.sales_orders.friendly.find(params[:id]) rescue nil
        @invoice = @order.try(:invoice)

        if @invoice
          @invoice.send_invoice
          flash[:success] = 'Email will be sent shortly'
        elsif States[@order.state].between?(States['cart'], States['complete'])
          flash.now[:error] = 'Must approve order before sending invoice'
        else
          flash.now[:error] = 'Could not find invoice'
        end
      end

      def generate
        @order = Spree::Order.includes(:line_items, :account, customer: :users).friendly.find(params[:order_id])
        if @order.account.inactive?
          flash.now[:error] = "This account has been deactivated. You must reactivate it before placing an order."
          redirect_to :back
        else
          order = Spree::Order.new(
            delivery_date: Date.current + @order.max_lead_time.days,
            vendor_id: @order.vendor_id,
            customer_id: @order.customer_id,
            account_id: @order.account_id,
            ship_address_id: @order.ship_address_id,
            bill_address_id: @order.bill_address_id,
            shipping_method_id: @order.account.try(:default_shipping_method_id) || @order.shipping_method_id
          )
          associate_user(order)
          delivery_date = get_num_until_next_available_day(generate_days(@order.account))[1]
          order.delivery_date = delivery_date != nil ? delivery_date : Date.today
          if @order.vendor.track_order_class?
            order.txn_class_id = @order.try(:txn_class_id) ? @order.try(:txn_class_id) : @order.account.try(:default_txn_class_id)
          end
          order.save
          data = []
          @order.line_items.each_with_index {|item,index| data << [index, { id: item.variant_id.to_s, quantity: item.quantity, pack_size: item.pack_size, txn_class_id: item.txn_class_id, position: item.position}]}
          order.contents.new_order(Hash[data])  





          redirect_to edit_manage_order_path(order), flash: { success: "Order has been created from Order ##{@order.display_number}" }
        end
      end

      def daily_packing_slips(date = nil, sort = 'spree_accounts.fully_qualified_name asc')
        @vendor = current_vendor
        date ||= overview_date_t

        sort = params[:sort] if params[:sort].present?
        if sort.start_with?('delivery_date')
          sort = "end_date #{sort.split(' ').last}"
        end

        if params[:approved_only] == 'true'
          @daily_orders = @vendor.sales_orders.approved.includes(:customer, :line_items).where('delivery_date = ?', date).order(sort)
        else
          @daily_orders = @vendor.sales_orders.complete.includes(:customer, :line_items).where('delivery_date = ? AND state IN (?)', date, InvoiceableStates).order(sort)
        end
        @bookkeeping_document = CombinePDF.new
        if @daily_orders.present?
          @daily_orders.each {|order| @bookkeeping_document << CombinePDF.parse(order.pdf_packaging_list_for_order.pdf)}

          respond_with(@bookkeeping_document) do |format|
            format.pdf do
              send_data @bookkeeping_document.to_pdf, filename: "#{date.strftime('%Y-%m-%d')}_daily_packing_slips.pdf", type: 'application/pdf', disposition: 'inline'
            end
          end
        else
          flash[:error] = "There are no orders with a #{@vendor.order_date_text} date of #{overview_date}"
          redirect_to :back
        end
      end

      def void
        unless current_spree_user.can_write?('basic_options', 'order')
          flash[:error] = 'You do not have permission to void transactions'
          redirect_to :back and return
        end

        if @order.void(current_spree_user.try(:id))
          flash[:success] = "Order #{@order.display_number} has been voided."
          redirect_to manage_orders_path
        else
          flash[:errors] = @order.errors.full_messages
          render :new
        end
      end

      def save_and_clear_order
        clear_current_order
        if params[:prev_controller].include?('orders')
          redirect_to manage_orders_url(q: {show_incomplete: true})
        elsif params[:prev_controller].include?('invoices')
          redirect_to manage_invoices_url
        else
          redirect_to manage_products_url
        end
      end

      def get_lot_qty
        @line_item = @order.line_items.find(params[:line_item_id])
        respond_to do |format|
          format.js do
            @line_item
          end
        end
      end

      def submit_lot_count
        @line_item = current_vendor.sales_line_items.find_by_id(params[:line_item])
        @order = @line_item.order
        order_hash = current_spree_user.permissions.fetch('order')
        @user_edit_line_item = order_hash.fetch('edit_line_item') && @order.try(:channel).to_s == 'sweet'
        @approve_ship_receive = order_hash.fetch('approve_ship_receive')
        if params[:line_item_lots].present? && params[:line_item].present?
          line_item_lots = params[:line_item_lots]
          line_item_lots.each do |lot_id, count|
            new_line_item_lot = Spree::LineItemLots.find_or_initialize_by(lot_id: lot_id, line_item_id: params[:line_item])
            new_line_item_lot.count = count
            if new_line_item_lot.count > 0
              new_line_item_lot.save
            else
              new_line_item_lot.destroy!
            end
          end
          if States[@order.state] >= States['shipped']
            @line_item.reload
            if @line_item.inventory_units.sum(:quantity) == @line_item.line_item_lots.sum(:count)
              @line_item.adjust_lot_counts
            end #otherwise wait for order update
          end
          flash.now[:success] = "Lot counts updated"
        end
      end

      protected

      def order_params
        params.require(:order).permit(:customer_id, :delivery_date, :special_instructions,
          :user_id, :state, :completed_at, :shipping_method_id, :po_number, :account_id,
          :shipment_total, :override_shipment_cost, :invoiced_at, :invoice_sent_at, :due_date,
          :sweetist_fulfillment_time, :sweetist_fulfillment_time_window, :invoice_date, :txn_class_id,
          shipments_attributes: [:tracking, :id],
          line_items_attributes: [
            :item_name, :quantity, :shipped_qty, :ordered_qty, :variant_id, :pack_size, :txn_class_id,
            :price, :lot_number, :lots, :id,
            inventory_units_attributes: [:lot_id],
            line_item_lots_attributes: [:lot_id, :count, :variant_part_id, :id]
            ]).tap do |ha|
              ha.fetch(:line_items_attributes, {}).values.each do |line_hash|
                line_hash[:quantity] = line_hash[:quantity].to_f
              end
            end
          # end
      end

      def approve_params
        params.require(:vendor).permit(:id,
          orders_attributes: [:approved, :order_id]
        )
      end

      def ensure_vendor
        @order = Spree::Order.friendly.find(params[:id])
        unless current_vendor.id == @order.vendor_id
          flash[:error] = "You don't have permission to view the requested page"
          redirect_to root_url
        end
      end

      def ensure_editable
        @order = Spree::Order.friendly.find(params[:id])
        unless @order.is_editable?
          flash[:error] = "This order has a state of #{@order.state} and can no longer be edited"
          redirect_to edit_manage_order_url(@order)
        end
      end

      def ensure_read_permission
        # defining instance variables here to be accessible in many views
        @order ||= current_order
        order_hash = current_spree_user.permissions.fetch('order')
        @user_basic_options = order_hash.fetch('basic_options')
        @user_edit_line_item = order_hash.fetch('edit_line_item') && @order.try(:channel).to_s == 'sweet'
        @approve_ship_receive = order_hash.fetch('approve_ship_receive')
        @manual_adjustment = order_hash.fetch('manual_adjustment') && @order.try(:channel).to_s == 'sweet'
        if @user_basic_options == 0
          flash[:error] = 'You do not have permission to view orders'
          redirect_to manage_path
        end
      end

      # payment
      def payment_params
        if params[:payment] and params[:payment_source] and source_params = params.delete(:payment_source)[params[:payment][:payment_method_id]]
          params[:payment][:source_attributes] = source_params
        end
        params.require(:payment).permit(permitted_payment_attributes)
      end

      def load_data
        # @amount = params[:amount] || load_order.total
        @payment_methods = current_vendor.payment_methods.available_on_back_end.active
        if @payment and @payment.payment_method
          @payment_method = @payment.payment_method
        else
          @payment_method = @payment_methods.first
        end
      end

      # def load_order
      #   @order = Spree::Order.friendly.where(number: params[:id])
      #   authorize! action, @order
      #   @order
      # end

      # def load_payment
      #   @payment = Spree::Payment.where(order_id: @order.id)
      # end

      def model_class
        Spree::Payment
      end

    end
  # /. Manage
  end
# /. Spree
end
