Spree::Order.class_eval do
  clear_validators!
  include Spree::Integrationable
  include Spree::Emailable
  include Spree::Order::Channel::Sweetist
  include Spree::Order::Weight
  include Spree::OrderRequirements
  include Spree::Order::Lots
  include Spree::Order::Purchase
  extend Spree::Order::Export

  States = {'void' => -2, 'canceled' => -1, 'cart' => 0, 'confirm' => 1, 'complete' => 2, 'approved' => 3, 'shipped' => 4, 'review' => 5, 'invoice' => 6}
  InvoiceableStates = %w{complete approved shipped review invoice}
  VoidableStates = %w{shipped review invoice}
  ApprovedStates = %w{approved shipped review invoice}

  NUMBER_LENGTH = 9
  DEFAULT_ORDER_PREFIX = 'R'

  before_validation :generate_number, on: :create # generate number before make_permalink

  validates :email, presence: true, if: :require_email
  validates :email, email: true, if: :require_email, allow_blank: true
  validate :has_available_shipment
  validates :number, presence: true, uniqueness: true

  validates :delivery_date, :account_id, :due_date, presence: true
  validate :special_instructions_length

  before_save :add_special_instructions

  before_create :set_order_currency
  before_validation :set_invoice_date, if: Proc.new { |order| order.id.nil? || order.invoice_date.nil? }
  before_validation :set_due_date, if: Proc.new { |order| order.id.nil? || order.due_date.nil? }

  # validate :shipping_method_presence

  belongs_to :vendor, class_name: 'Spree::Company', foreign_key: :vendor_id, primary_key: :id
  has_one :customer, class_name: 'Spree::Company', through: :account, source: :customer
  belongs_to :transaction_class, class_name: "Spree::TransactionClass", foreign_key: :txn_class_id, primary_key: :id

  belongs_to :account, class_name: 'Spree::Account', foreign_key: :account_id, primary_key: :id
  has_one :primary_cust_contact, through: :account, source: :primary_cust_contact
  has_one :primary_vendor_contact, through: :account, source: :primary_vendor_contact
  has_one :standing_order_schedule, class_name: 'Spree::StandingOrderSchedule', foreign_key: :order_id, primary_key: :id
  has_one :standing_order, through: :standing_order_schedule, source: :standing_order
  belongs_to :shipping_method, class_name: 'Spree::ShippingMethod', foreign_key: :shipping_method_id, primary_key: :id
  acts_as_commontable
  has_many :integration_sync_matches, as: :integration_syncable, class_name: 'Spree::IntegrationSyncMatch', dependent: :destroy
  has_many :integration_actions, as: :integrationable, class_name: 'Spree::IntegrationAction'
  belongs_to :invoice, class_name: 'Spree::Invoice', foreign_key: :invoice_id, primary_key: :id
  has_many :lots, through: :line_items, source: :lots
  has_many :line_item_lots, through: :line_items, source: :line_item_lots
  # PDF Invoice calls
  has_many :bookkeeping_documents, as: :printable, dependent: :destroy
  has_one :packaging_slip, -> { where(template: 'packaging_slip') },
          class_name: 'Spree::BookkeepingDocument',
          as: :printable
  has_one :pdf_purchase_order, -> { where(template: 'purchase_order') },
          class_name: 'Spree::BookkeepingDocument',
          as: :printable
  # ./ PDF Invoice calls
  scope :approved, -> { where(state: ApprovedStates) }
  scope :unapproved, -> { where('approved_at IS NULL') }
  scope :shipped, -> { where(state: 'shipped') }
  scope :invoiceable, -> { where(state: InvoiceableStates)}

  self.whitelisted_ransackable_associations += %w[customer vendor account lots shipping_method]
  self.whitelisted_ransackable_attributes += %w[delivery_date approved_at item_total item_count approved account_id customer_id shipped_qty shipped_total po_number invoice_date due_date]

  attr_accessor :skip_update, :skip_notify

  def invoice_due_date=(date)
    self.invoice.try(:update_columns, {due_date: date}) rescue nil
  end
  def invoice_due_date
    self.due_date rescue nil
  end

  def set_invoice_date
    self.invoice_date = self.delivery_date
  end

  attr_default :custom_attrs do
    {}
  end
  remove_checkout_step :address
  remove_checkout_step :delivery
  remove_checkout_step :payment

  checkout_flow do

    # go_to_state :confirm, if: ->(order) { order.confirmation_required? }
    go_to_state :complete
    go_to_state :approved
    go_to_state :shipped
    go_to_state :review, if: ->(order) { order.receiving_discrepancy? }
    go_to_state :invoice

  end

  def generate_number(options = {})
    return self.number if self.number && self.number.start_with?(prefix_scope) && !options[:renumber]

    if self.number && !self.number.start_with?(prefix_scope) && !options[:renumber]
      prev_num = self.number.split('-')[1..-1].join('-')
      if prev_num.present?
        self.number = "#{prefix_scope}#{prev_num}"
        return self.number
      end
    end

    if vendor
      options[:prefix] = prefix_scope
      options[:prefix] += vendor.order_prefix.nil? ? "#{DEFAULT_ORDER_PREFIX}" : "#{vendor.order_prefix}"
      # options[:length] = vendor.order_next_number.present? ? vendor.order_next_number.length : NUMBER_LENGTH
    end
    self.number = nil if options[:renumber]
    if vendor.try(:use_sequential_order_number?)
      next_number = vendor.order_next_number.to_s
      loop do
        self.number = "#{options[:prefix].to_s.strip}#{next_number}"
        # get original number length with padding
        len = next_number.length
        # increase numerical value
        next_number = next_number.to_i + 1
        # get length of numerical value
        len2 = next_number.to_s.length
        # get the number of zeros for padding after the number increases
        # need this for when number length increases Ex. 0009999 + 1 = 0010000
        pad_length = [len - len2, 0].max
        # reassemble next_number
        next_number = "#{'0' * pad_length}#{next_number}"

        break unless Spree::Order.exists?(number: self.number)
      end

      vendor.order_next_number = next_number
      vendor.update_columns(invoice_settings: vendor.invoice_settings)
    else
      # Always hiding first letter so use 'RR'
      options[:prefix] ||= "#{prefix_scope}#{DEFAULT_ORDER_PREFIX}"
      super
    end

    self.number
  end

  def display_number
    return po_display_number if purchase_order? && po_display_number
    # Strip the DEFAULT_ORDER_PREFIX from the number
    start = prefix_scope.length
    number.to_s.slice(start..-1)
  end

  def set_email(acc = nil)
    acc ||= self.account
    return unless acc

    self.email = acc.customer_emails_string
  end

  def prefix_scope
    "#{DEFAULT_ORDER_PREFIX}#{vendor_id}-"
  end

  def self.number_from_integration(num, vendor_id)
    "#{DEFAULT_ORDER_PREFIX}#{vendor_id}-#{num}"
  end

# BEGIN STATE MACHINE #########################################
  state_machine do

    after_transition from: any, to: any - [:confirm] do |order|
      order.update_totals
      order.persist_totals
    end

    # Create a new invoice before transitioning to complete
    before_transition to: :complete do |order|
      order.pdf_packaging_list_for_order
    end

    after_transition from: :cart, to: :complete do |order|
      unless order.any_variant_past_cutoff?(order.delivery_date)
        if order.vendor.try(:auto_approve_orders) && !order.is_from_standing_order?
          order.approve
        elsif order.auto_approve_standing_order?
          order.approve
        end
      end
    end

    after_transition to: :complete do |order|
      if order.purchase_order? && order.account.send_purchase_orders_emails
        Spree::OrderMailer.purchase_order_submit_email(order).deliver_later
      end
      order.update_order_dates
      order.update_inventory
      order.notify_integration unless order.skip_notify
    end

    after_transition to: :approved do |order|
      order.update_columns(approved_at: Time.current) if order.approved_at.nil?
      order.update_invoice
      if !order.approved?
        if order.vendor.try(:auto_approve_orders)
          order.deliver_order_confirmation_email
          order.deliver_vendor_confirmation if order.created_by_customer? #don't send if created by vendor user
        else
          if order.created_by.try(:company_id) == order.vendor_id
            order.deliver_order_confirmation_email
          else
            Spree::OrderMailer.approved_email(order.id).deliver_later
          end
        end
        order.update_columns(approved: true)
      end
      order.notify_integration
    end

    after_transition to: :canceled do |order|
      order.remove_from_invoice
      if order.purchase_order?
        Spree::OrderMailer.purchase_order_cancel_email(order).deliver_later if order.account.send_purchase_orders_emails
      else
        Spree::OrderMailer.cancel_email(order.id).deliver_later
      end

      # later add a boolean value for whether we want to be informed
      # for now, removing internal confirmation # 2/22/16
      if false
        Spree::OrderMailer.internal_cancellation_notice(order.id).deliver_later
      end
      order.notify_integration
    end

    after_transition to: :shipped do |order|
      order.update_invoice
      order.update_inventory
      order.adjust_lot_counts
      order.notify_integration

      unless order.vendor.try(:receive_orders)
        order.shipments.each do |shipment|
          Spree::ShipmentHandler.factory(shipment).perform
        end
        order.skip_update = true
        order.next
      end
    end

    after_transition to: :review do |order|
      unless order.skip_update
        order.update_invoice
        # update shipments and inventory units if order.state == 'shipped' is skipped
        order.shipments.where(shipped_at: nil).update_all(shipped_at: Time.current)
        order.update_inventory
        order.inventory_units.on_hand.each &:ship!
        order.adjust_lot_counts
      end
      unless order.account.email.blank?
        Spree::OrderMailer.review_order_email(order.id).deliver_later
        Spree::VendorMailer.review_order_email(order.id).deliver_later
      end
    end

    after_transition to: :invoice do |order|
      unless order.skip_update
        order.update_invoice
        # update shipments and inventory units if order.state == 'shipped' is skipped
        order.shipments.where(shipped_at: nil).update_all(shipped_at: Time.current)
        order.update_inventory
        order.inventory_units.on_hand.each &:ship!
        order.adjust_lot_counts
        order.notify_integration
      end
      Spree::OrderMailer.final_invoice_email(order.id).deliver_later unless order.invoiced_at && order.invoice_sent_at
      order.update_columns(invoiced_at: Time.current)
    end

    event :receive_purchase_order do
      transition [:complete, :approved, :shipped] => :invoice
      # order.restock_receive_at_location
    end
  end

  def receive_purchase_order(*args)
    if result = super
      self.restock_receive_at_location
    end

    result
  end
  # END STATE MACHINE #########################################

  def sales_order?(company_id = nil)
    if company_id
      company_id == vendor_id
    else
      order_type == 'sales' ? true : false
    end
  end

  def order_type=(value)
    if value == "sales"
      self[:order_type] = "sales"
      return true
    elsif value == "purchase"
      self[:order_type] = "purchase"
      return true
    else
      raise ArgumentError, "\"#{value}\" is not a valid order type"
      return false
    end
  end

  def set_to_sales_order
    self.order_type = "sales"
    self.save
  end

  def self.view_editable_attributes
    #should return array of attributes
    ['payment_state']
  end

  def self.mark_many_paid(vendor, order_ids = [])
    return unless vendor
    vendor.sales_orders.where(id: order_ids).each {|o| o.mark_paid }
  end

  def self.mark_many_unpaid(vendor, order_ids)
    return unless vendor
    vendor.sales_orders.where(id: order_ids).each {|o| o.mark_unpaid }
  end

  def notify_integration
    if Spree::IntegrationItem.where(vendor_id: [self.vendor_id, self.customer.try(:id)], order_sync: true).any?
      Sidekiq::Client.push(
        'at' => Time.current.to_i + 2.seconds,
        'class' => OrderSync,
        'queue' => 'integrations',
        'args' => [self.id]
      )
    end
  end

  def sync_payments
    self.payments.each(&:notify_integration)
  end

  def send_as_invoice
    self.invoiced_at.present? && self.invoice_sent_at.blank?
  end

  def has_shipped?
    States[self.state] >= States["shipped"]
  end

  def is_from_standing_order?
    self.standing_order.presence rescue false
  end

  def auto_approve_standing_order?
    self.standing_order.try(:auto_approve)
  end

  def created_by_customer?
    return false unless self.created_by
    self.created_by.company_id == self.account.try(:customer_id)
  end

  def created_by_vendor?
    return false unless self.created_by
    self.created_by.company_id == self.vendor_id
  end

  def valid_address?
    (self.ship_address.try(:state).present? && self.ship_address.try(:zipcode).present? && self.ship_address.try(:city).present?) ||
    (self.ship_address.nil? && self.bill_address.try(:state).present? && self.bill_address.try(:zipcode).present? && self.bill_address.try(:city).present?)
  end

  def name_for_integration
    if self.invoice && self.invoice.number != self.display_number
      "Order #{self.display_number} / Invoice #{self.invoice.number} for: #{self.account.try(:fully_qualified_name)}"
    else
      "Order: #{self.display_number} for: #{self.account.try(:fully_qualified_name)}"
    end
  end

  def invoice_number
    self.invoice.try(:number)
  end

  def previous_state
    States.key(States[self.state] - 1) rescue nil
  end

  def trigger_transition
    return unless States[self.state] > States['cart']
    self.send("back_to_#{self.previous_state}")
    self.next
  end

  def back_to_cart
    self.update_columns(
      state: 'cart',
      updated_at: Time.current,
      completed_at: nil,
      #approver_id: nil,
      approved_at: nil,
      approved: false
    )
  end

  def back_to_confirm
    back_to_cart
  end

  def back_to_complete
    self.update_columns(
      state: 'complete',
      updated_at: Time.current,
      approved_at: nil
      # approved: false #testing
    )
  end

  def back_to_approved
    self.update_columns(
      state: 'approved',
      updated_at: Time.current
    )
  end
  def back_to_shipped
    self.update_columns(
      state: 'shipped',
      updated_at: Time.current
    )
  end
  def back_to_review
    self.update_columns(
      state: 'review',
      updated_at: Time.current
    )
  end
  def unapprove
    self.update_columns(
      state: 'complete',
      updated_at: Time.current,
      approved_at: nil,
      approved: false
    )
  end
 def add_special_instructions
    self.special_instructions = self.account.note.body if self.account.try(:note) && self.special_instructions.blank?
  end

  def receiving_discrepancy?
    return false unless self.vendor.try(:receive_orders)
    line_items.any?{|li| li.quantity != li.shipped_qty}
  end

  def action
  end

  def set_order
    self.create_proposed_shipments
  end

  def set_order_currency
    self.currency = self.purchase_order? ? customer.try(:currency) : vendor.try(:currency)
  end

  def require_email
    return false
  end

  def payment_required?
    false
  end

  def received?
    self.shipment_state == 'received'
  end

  def approved?
    approved
  end

  def is_editable?
    States[self.state] <= self.vendor.last_editable_order_state
  end

  def any_variant_past_cutoff?(date = nil)
    self.line_items.any? do |line_item|
      line_item.is_past_cutoff?(date)
    end
  end

  def all_variants_past_cutoff?
    return false if self.line_items.count == 0
    self.line_items.all? do |line_item|
      line_item.is_past_cutoff?
    end
  end

  def inventory_items
    self.variants.where(variant_type: INVENTORY_TYPES.keys)
  end

  def has_unsynced_inventory_items?(integration_key)
    return false unless self.vendor && self.vendor.has_integration?(integration_key)
    variant_ids = self.inventory_items.ids
    return false if variant_ids.empty?
    self.vendor.integration_items.where(integration_key: integration_key).any? do |integration_item|
      integration_item.integration_sync_matches
      .where('integration_syncable_id IN (?) AND integration_syncable_type = ? AND sync_id IS NOT NULL', variant_ids, 'Spree::Variant').count != variant_ids.count
    end || self.products.where(product_type: BUNDLE_TYPES.keys).any?{|p| p.has_unsynced_inventory?(integration_key)}
  end

  def max_lead_time #returns the maximum lead time for any variant in the order or 0 if empty
    self.line_items.joins(:variant).maximum('spree_variants.lead_time') || 0
  end

  def valid_delivery_date? #do not use on vendor side.  Allow vendor to select any date they wish
    if self.delivery_date.blank?
      errors.add(:delivery_date, "can't be blank") unless errors.any? {|e| e.messages.include?("blank")}
      return false
    end
    return true if self.vendor.blank? #needed for when admin creates an order
    return true if self.approved? #allows shipped and received quantities to be updated without causing error

    if (delivery_date - vendor.min_lead_days).to_date == Time.current.in_time_zone(vendor.time_zone).to_date
      if Time.current.in_time_zone(vendor.time_zone) > vendor.order_cutoff_time.in_time_zone(vendor.time_zone)
        errors.add(:delivery_date, "is past the cutoff period. Please select a later date.")
        return false
      end
    elsif (delivery_date - vendor.min_lead_days).to_date < Time.current.in_time_zone(vendor.time_zone).to_date
      errors.add(:delivery_date, "is past the cutoff period. Please select a later date.")
      return false
    end

    return true
  end

  def shipping_method_presence
    unless self.purchase_order? # skip validation for purchase orders
      if self.shipping_method_id.blank? || self.vendor.nil?
        errors.add(:shipping_method_id, "can't be blank. This may be caused by no shipping methods being set up.")
        false
      else
        true
      end
    else
      return true
    end
  end

  def available_shipping_methods
    self.vendor.shipping_categories
    if self.vendor && self.line_items
      ship_methods = Hash.new(0)
      total_products = self.products.count
      self.products.where(vendor_id: self.vendor_id).each do |p|
        p.shipping_methods.each{ |sm| ship_methods[sm] += 1}
      end
      if self.ship_address.try(:city) || self.ship_address.try(:state) || self.ship_address.try(:country)
        ship_methods.keep_if{|sm,product_count| product_count == total_products && sm.include?(self.shipping_address)}.keys
      else
        ship_methods.keep_if{|sm,product_count| product_count == total_products}.keys
      end
    end
  end

  def available_shipping_method_ids
    self.available_shipping_methods.map(&:id).sort
  end

  def no_shipping_method_products
    self.products.select{|p| p.shipping_methods.blank?}
  end

  def set_shipping_method
    @available_shipping_method_ids = self.available_shipping_method_ids
    if @available_shipping_method_ids.blank?
      self.shipping_method_id = nil
    elsif @available_shipping_method_ids.include?(self.shipping_method_id)
      self.shipping_method_id
    elsif @available_shipping_method_ids.include?(self.account.default_shipping_method_id)
      self.shipping_method_id = self.account.default_shipping_method_id
    else
      self.shipping_method_id = @available_shipping_method_ids.first
    end
  end

  def ensure_updated_shipments
    if shipments.any? && !self.line_items.exists?
      self.shipments.destroy_all
      self.update_column(:shipment_total, 0)
      restart_checkout_flow
    end
  end

  def is_valid?
    self.valid? && self.line_items.all?(&:valid?)
  end
  def errors_including_line_items
    self.errors.full_messages + self.line_items.map{|li| li.errors.full_messages }.flatten
  end

  def customer_can_submit?(ignore_order_rules = false)
    return false if self.account.try(:inactive?)
    self.available_shipping_methods.present? &&
    ( ignore_order_rules || self.errors_from_order_rules.empty? ) &&
    (
      !self.account.payment_due_before_submit? || self.paid? || self.final_payments_pending?
    )
  end
  def disable_customer_submit?
    !customer_can_submit?
  end
  def disable_customer_resubmit?
    self.account.payment_due_before_submit?
  end

  def create_shipment!
    errors = []
    begin
      self.shipping_method_id = set_shipping_method
      stock_location = self.account.try(:default_stock_location)
      stock_location = nil unless stock_location.try(:active)
      stock_location ||= self.vendor.default_stock_location || self.vendor.stock_locations.active.first || self.vendor.stock_locations.first
      shipment = self.shipments.create(stock_location_id: stock_location.id)
      self.line_items.where.not(id: nil).each do |line_item|
        line_item.update_inventory
      end

      sm = self.vendor.shipping_methods
      shipment.add_shipping_method(self.shipping_method, true) if self.shipping_method

      shipment.state = 'pending'
      self.shipment_state = 'pending'
      self.save!
    rescue Exception => e
      if e.is_a?(TaxCloud::Errors::ApiError)
        errors << "An error occured while calculating the tax. Please check that there is a valid shipping address"
      else
        if e.try(:message)
          errors << e.try(:message)
        else
          errors << 'There was an error processing your request'
        end
      end
    end
    errors.compact.uniq
  end

  def approve(user = nil)
    begin
      user ||= self.vendor.users.first
      if self.override_shipment_cost
        self.shipments.each do |s|
          s.refresh_rates
          s.update_amounts
        end
      end
      if self.is_valid?
        if self.state == 'cart' #transition to complete
          self.skip_notify = true
          self.next!
          @from_cart = true
        end

        if self.state == 'complete'
          self.create_shipment! if self.shipments.none?
          self.update_columns(
            approver_id: user.try(:id),
            approved_at: Time.current,
            payment_state: updater.update_payment_state
          )
          self.shipments.update_all(state: 'ready')
          self.skip_notify = false
          self.next! #transition to approved
          # need to reload the order here because if the vendor
          unless @from_cart
            self.line_items.each do |line_item|
              line_item.update_columns(ordered_qty: line_item.quantity)
              line_item.update_inventory
            end
          end
        end

        errors = []
      else
        self.errors_including_line_items
      end
    rescue Exception => e
      self.errors.add(:base, "An error occurred trying to approve order #{self.display_number}")
      was_approved = self.reload.approved_at
      self.back_to_complete if self.state == 'approved'
      Airbrake.notify(
        error_message: e.message,
        error_class: e.class,
        parameters: {
          order_id: self.id,
          order_number: self.number,
          from_standing_order: self.is_from_standing_order?.to_s,
          standing_order_schedule_id: self.standing_order_schedule.try(:id),
          standing_order_id: self.standing_order.try(:id),
          standing_order_auto_approve: self.auto_approve_standing_order?.to_s,
          auto_approve: self.vendor.try(:auto_approve_orders).to_s,
          approved_at: was_approved.to_s,
          order_state: self.state
        }
      )
      [e.message]
    end
  end

  def receive(user = nil)
    user ||= self.customer.users.first

    if self.is_valid? && self.state == 'complete'
      self.receive_purchase_order

      # self.create_shipment! if self.shipments.none?
      self.update_columns(approver_id: user.try(:id), approved_at: Time.current)
      # self.shipments.update_all(state: 'ready')
      # self.next #transition to approved

      errors = []
    else
      self.errors_including_line_items
    end
  end

  def tax_zone
    @tax_zone ||= Spree::Zone.match(tax_address, self.vendor_id) || Spree::Zone.default_tax(self.vendor_id)
  end

  #OVERRIDE SPREE to always try the ship_address first for tax_address
  def tax_address
    self.ship_address || self.bill_address
  end

  # Creates new tax charges if there are any applicable rates. If prices already
  # include taxes then price adjustments are created instead.
  def create_tax_charge!
    unless self.account.try(:is_tax_exempt?)
      Spree::TaxRate.adjust(self, line_items)
      Spree::TaxRate.adjust(self, shipments) if shipments.any?
    end
  end

  #----- BEGIN PAYMENTS ------------------------------------------
  def outstanding_balance
    if state == 'canceled' || state == 'void'
      -1 * payment_total
    elsif reimbursements.includes(:refunds).size > 0
      reimbursed = reimbursements.includes(:refunds).inject(0) do |sum, reimbursement|
        sum + reimbursement.refunds.sum(:amount)
      end
      # If reimbursement has happened add it back to total to prevent balance_due payment state
      # See: https://github.com/spree/spree/issues/6229
      total - (payment_total + reimbursed)
    else
      total - payment_total
    end
  end

  def pending_balance
    pending_total = self.payments.where(state: %w[checkout pending processing]).sum(:amount)
    if state == 'canceled' || state == 'void'
      -1 * pending_total
    else
      pending_total
    end
  end

  def paid_or_pending_balance
    payment_sum = self.payments.where(state: %w[checkout pending processing completed]).sum(:amount)
    if reimbursements.includes(:refunds).size > 0
      reimbursed = reimbursements.includes(:refunds).inject(0) do |sum, reimbursement|
        sum + reimbursement.refunds.sum(:amount)
      end

      payment_sum - reimbursed
    else
      payment_sum
    end
  end

  def paid_balance
    payment_sum = self.payments.where(state: 'completed').sum(:amount)
    if reimbursements.includes(:refunds).size > 0
      reimbursed = reimbursements.includes(:refunds).inject(0) do |sum, reimbursement|
        sum + reimbursement.refunds.sum(:amount)
      end

      payment_sum - reimbursed
    else
      payment_sum
    end
  end

  def remaining_balance
    outstanding_balance - pending_balance
  end

  def final_payments_pending?
    # check less than or eq in case order is edited and payment exceeds amount due
    self.outstanding_balance - self.pending_balance <= 0
  end

  def payment_status(use_state = false)
    return self.payment_state if use_state
    if self.payment_state == 'pending'
      'paid'
    else
      self.payment_state
    end
  end

  def can_mark_paid?
    !self.paid? && !self.final_payments_pending?
  end

  def can_mark_unpaid?
    self.paid_or_pending_balance < self.total
  end

  def mark_paid(should_update_invoice = true)
    if can_mark_paid?
      self.update_columns(
        payment_total: self.total,
        payment_state: 'paid'
      )
      if should_update_invoice
        self.reload
        self.update_invoice
      end
      true
    else
      self.errors.add(:payment, 'cannot be marked PAID')
      false
    end
  end

  def mark_unpaid(should_update_invoice = true)
    if can_mark_unpaid?
      self.update_columns(payment_total: self.paid_balance)
      self.reload
      self.update_columns(payment_state: updater.update_payment_state)
      if should_update_invoice
        self.reload
        self.update_invoice
      end
      true
    else
      self.errors.add(:payment, 'cannot be marked UNPAID')
      false
    end
  end

  #---- END PAYMENTS ------------------------------------------

  ### OVERRIDE OF BASE SPREE finalize! CALL ###
  # Finalizes an in progress order after checkout is complete.
  # Called after transition to complete state
  def finalize!
    # lock all adjustments (coupon promotions, etc.)
    all_adjustments.each{|a| a.close}

    # update payment and shipment(s) states, and save
    #updater.update_payment_state
    shipments.each do |shipment|
      shipment.update!(self)
      shipment.finalize!
    end

    updater.update_shipment_state
    save!
    updater.run_hooks

    touch :completed_at
    if self.created_by_customer?
      unless self.vendor.try(:auto_approve_orders)
        if !confirmation_delivered?
          self.deliver_vendor_confirmation
        elsif confirmation_delivered? && self.approver_id
          self.deliver_vendor_confirmation(true)
        end
        # changing this so that customer will receive an order confirmation email when order is updated
        # only send if order was created by customer (otherwise will be sent after transition to approve)
        deliver_order_confirmation_email
      end
    end

    consider_risk
  end

  def deliver_vendor_confirmation(resend=false)
    Spree::VendorMailer.confirm_email(self.id, resend).deliver_later

    # later add a boolean value for whether we want to be informed
    # for now, removing internal confirmation # 2/22/16
    if false
      Spree::OrderMailer.internal_confirmation(self.id).deliver_later
    end
  end

  def send_cancel_email
    # overide because we send cancel email through our hook
  end

  def account_handle
    self.account.fully_qualified_name
  end

  def account_vendor_handle
    # This is used for the Dear <name> in purchase_order emails
    # using account name because it is editable by customer, but vendor.name is not
    # eventually we should have two names on the account, one for customer, one for vendor
    self.account.fully_qualified_name
  end

  def next_mailer_setting_message
    case self.state
    when 'cart', 'complete'
      if self.vendor.send_approved_email && self.vendor.send_approved_email_invoice
        "Invoice will be sent on '#{Spree.t('order.actions.approve')}'"
      elsif self.vendor.send_approved_email
        "Approved email will be sent on '#{Spree.t('order.actions.approve')}'"
      else
        "Automated email will NOT be sent on '#{Spree.t('order.actions.approve')}'"
      end
    when 'approved'
      if self.vendor.send_shipped_email && (self.vendor.send_final_invoice_email && !self.vendor.receive_orders && !(self.invoice.try(:confirm_sent) || self.invoice_sent_at))
        "Shipment notification and invoice emails will be sent on '#{Spree.t('order.actions.ship')}'"
      elsif self.vendor.send_shipped_email
        "Shipment notification email will be sent on '#{Spree.t('order.actions.ship')}'"
      elsif (self.vendor.send_final_invoice_email && !self.vendor.receive_orders) && !(self.invoice.try(:confirm_sent) || self.invoice_sent_at)
        "Automated invoice email will be sent on '#{Spree.t('order.actions.ship')}'"
      else
        "Automated email will NOT be sent on '#{Spree.t('order.actions.ship')}'"
      end
    when 'shipped'
      if self.vendor.send_final_invoice_email && !(self.invoice.try(:confirm_sent) || self.invoice_sent_at)
        "Invoice will be sent on '#{Spree.t('order.actions.confirm_delivered')}'"
      else
        "Automated email will NOT be sent on '#{Spree.t('order.actions.confirm_delivered')}'"
      end
    when 'review'
      if self.vendor.send_final_invoice_email && !(self.invoice.try(:confirm_sent) || self.invoice_sent_at)
        "Invoice will be sent on '#{Spree.t('order.actions.finalize')}'"
      else
        "Automated email will NOT be sent on '#{Spree.t('order.actions.finalize')}'"
      end
    else
      ''
    end
  end

  ##################################
  ######## BEGIN PDF INVOICE #######
  ##################################

  # Backwards compatibility stuff. Please don't use these methods, rather use the
  # ones on Spree::BookkeepingDocument
  #
  def pdf_file
    ActiveSupport::Deprecation.warn('This API has changed: Please use order.pdf_invoice.pdf instead')
    pdf_invoice.pdf
  end

  def pdf_filename
    ActiveSupport::Deprecation.warn('This API has changed: Please use order.pdf_invoice.file_name instead')
    pdf_invoice.file_name
  end

  def pdf_file_path
    ActiveSupport::Deprecation.warn('This API has changed: Please use order.pdf_invoice.pdf_file_path instead')
    pdf_invoice.pdf_file_path
  end

  def pdf_storage_path(template)
    ActiveSupport::Deprecation.warn('This API has changed: Please use order.{packaging_slip}.pdf_file_path instead')
    bookkeeping_documents.find_by!(template: template).file_path
  end

  def pdf_packaging_list_for_order
    self.packaging_slip.present? ? self.packaging_slip : bookkeeping_documents.create(template: 'packaging_slip')
  end

  def pdf_purchase_order_for_order
    self.pdf_purchase_order.present? ? self.pdf_purchase_order : bookkeeping_documents.create(template: 'purchase_order')
  end

  ##################################
  ######## END PDF INVOICE #########
  ##################################

  def display_date
    "#{DateHelper.display_vendor_date_format(self.delivery_date, self.vendor.date_format)}"
  end

  def display_due_date
    "#{DateHelper.display_vendor_date_format(self.due_date, self.vendor.date_format)}"
  end

  def display_invoice_date
    "#{DateHelper.display_vendor_date_format(self.invoice_date, self.vendor.date_format)}"
  end

  def display_state
    "#{self.state == 'compete' ? 'submitted' : self.state}".capitalize
  end

  def pack_list_customer_details
    address = self.account.try(:shipping_addresses).try(:first)
    [
      "Order #: #{self.display_number}",
      "Item Count: #{self.item_count}",
      "Ship via: #{self.shipping_method.try(:name)}",
      "Ship to:",
      "#{self.account.try(:fully_qualified_name)}",
      "#{address.try(:address1)}",
      "#{address.try(:address2)}",
      "#{address.try(:city)} #{address.try(:state).try(:abbr)} #{address.try(:zipcode)}"
    ].reject(&:blank?).join("\n")
  end

  def update_invoice(force_individual = false)
    if force_individual
      old_invoice = self.invoice
      self.update_columns(invoice_id: nil)
      Spree::Invoice.create_from_one_order(self)
      old_invoice.try(:update_multi_counts)
    elsif self.vendor.multi_order_invoice
      self.update_multi_order_invoice
    else
      self.update_one_to_one_invoice
    end
  end

  def update_multi_order_invoice
    old_invoice = self.invoice
    unless old_invoice && self.delivery_date.between?(old_invoice.start_date, old_invoice.end_date)
      if self.vendor.multi_order_invoice
        new_invoice = Spree::Invoice.find_or_create_for_account_by_delivery_date(self.account, self.delivery_date)
        self.update_columns(invoice_id: new_invoice.id)
        new_invoice.update_multi_counts
      else
        Spree::Invoice.create_from_one_order(self)
      end
    end
    old_invoice.try(:update_multi_counts)
  end

  def update_one_to_one_invoice
    invoice = self.invoice
    if invoice
      if invoice.multi_order?
        self.update_multi_order_invoice
      else
        invoice.update_one_to_one_counts(self)
      end
    else
      Spree::Invoice.create_from_one_order(self)
    end
  end

  def remove_from_invoice
    old_invoice = self.invoice
    if old_invoice
      self.update_columns(invoice_id: nil)
      if old_invoice.multi_order?
        old_invoice.update_multi_counts
      else
        old_invoice.destroy!
      end
    end
  end

  def update_inventory
    self.line_items.each do |li|
      li.update_inventory
    end
  end

  def void(user_id = nil, should_update_invoice = true)

    begin
      if VoidableStates.include?(self.state)
        self.shipments.each(&:void)
        self.update_columns(
          canceled_at: Time.current,
          canceler_id: user_id,
          state: 'void',
          shipment_state: 'void'
        )
        self.reload
        self.update_columns(payment_state: updater.update_payment_state)
        unstock_receive_at_location if purchase_order?
        if should_update_invoice
          self.reload
          self.update_invoice
        end
        self.notify_integration
        true
      else
        self.errors.add(:state, "cannot transition from #{self.state} to void")
        false
      end
    rescue Exception => e
      self.errors.add(:base, e.message)
      false
    end
  end

  def refresh_shipment_rates(shipping_method_filter = ShippingMethod::DISPLAY_ON_FRONT_AND_BACK_END, override = false)
    shipments.map { |s| s.refresh_rates(shipping_method_filter) }
  end

  def send_emails?
    order_channel = self.channel.downcase

    if order_channel == 'sweet'
      true
    else
      !!self.vendor.integration_items.find_by_integration_key(order_channel).try("#{order_channel}_send_automated_emails")
    end
  end

  def update_order_dates
    if created_by_customer?
      if self.vendor.try(:selectable_delivery)
        date = self.delivery_date
        self.invoice_date = date
      else
        date = DateHelper.sweet_today(self.vendor.try(:time_zone))
        self.invoice_date = date
        self.delivery_date = date
      end
      self.update_columns(
        delivery_date: date,
        invoice_date: date,
        due_date: date += self.account.try(:payment_terms).try(:num_days).to_i.days
      )
    elsif !self.account.try(:can_select_delivery?)
      self.update_columns(
        delivery_date: self.completed_at.in_time_zone(self.vendor.time_zone).to_date || DateHelper.sweet_today(self.vendor.try(:time_zone))
      )
    end
  end

  def special_instructions_length
    max_char = 1000
    if self.special_instructions.to_s.length > max_char
      self.errors.add(:special_instructions, "character limit is #{max_char} characters. You have entered #{self.special_instructions.length} characters.")
      false
    else
      true
    end
  end

  def state_text
    if self.state == 'complete'
      'Submitted'
    elsif self.state == 'invoice' && self.purchase_order?
      'Received'
    else
      self.try(:state).try(:capitalize)
    end
  end

  def viewable_comments?(user)
    self.thread.comments.any? { |comment| (comment.share_level == "public")||(comment.share_level == ::SHARE_LEVELS.last && comment.creator_id == user.id) || (comment.share_level == ::SHARE_LEVELS.first && comment.creator.company_id == user.company_id)}
  end

  def set_due_date(acc = nil)
    acc ||= self.account
    base_date = invoice_date || delivery_date
    if base_date.nil?
      self.errors.add(:base, "Cannot calculate due date without a starting date")
    else
      self.due_date = base_date += acc.try(:payment_terms).try(:num_days).to_i.days rescue nil
    end
  end
end
