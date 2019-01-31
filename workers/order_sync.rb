class OrderSync
  include Sidekiq::Worker

  def perform(order_id)
    order = Spree::Order.find(order_id)
    order.sync_payments if order.state == 'approved'
    account = order.account
    Spree::IntegrationItem.where(order_sync: true, vendor_id: [account.customer_id, account.vendor_id]).each do |integration_item|
      next if integration_item.vendor_id == account.vendor_id && !integration_item.should_sync_order(order.channel)
      next if integration_item.vendor_id == account.customer_id && !integration_item.should_sync_purchase_order(order.channel)
      next if order.state == 'complete' && integration_item.vendor_id == order.vendor_id
      if Spree::IntegrationAction.where(integrationable: order, integration_item: integration_item, status: [-1, 0]).empty?
        action = Spree::IntegrationAction.create(integrationable: order, integration_item: integration_item)
        Sidekiq::Client.push(
          'at' => Time.current.to_i + 10.seconds,
          'class' => IntegrationWorker,
          'queue' => integration_item.queue_name,
          'args' => [action.id]
        ) # unless (integration_item.method("#{integration_item.integration_key}_group_sync").call rescue true)
      else
        action = Spree::IntegrationAction.where(integrationable: order, integration_item: integration_item, status: -1).last
        if action
          action.update_columns(
            enqueued_at: Time.current,
            processed_at: nil,
            status: 0
          )
          Sidekiq::Client.push('class' => IntegrationWorker, 'queue' => integration_item.queue_name, 'args' => [action.id])
        end
      end
    end
  rescue ActiveRecord::RecordNotFound
    true # moving on if order has been removed from DB
  end

end
