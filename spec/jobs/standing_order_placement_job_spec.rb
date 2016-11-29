require 'spec_helper'

describe StandingOrderPlacementJob do
  let(:shop) { create(:distributor_enterprise) }
  let(:order_cycle1) { create(:simple_order_cycle, coordinator: shop) }
  let(:order_cycle2) { create(:simple_order_cycle, coordinator: shop) }
  let(:schedule1) { create(:schedule, order_cycles: [order_cycle1]) }
  let(:schedule2) { create(:schedule, order_cycles: [order_cycle1, order_cycle2]) }
  let(:standing_order1) { create(:standing_order_with_items, shop: shop, schedule: schedule1) }
  let(:standing_order2) { create(:standing_order_with_items, shop: shop, schedule: schedule2) }

  let!(:job) { StandingOrderPlacementJob.new(order_cycle1) }

  describe "finding standing_order orders for the specified order cycle" do
    let(:order1) { create(:order, order_cycle: order_cycle1, completed_at: 5.minutes.ago) } # Complete + Linked + OC Matches
    let(:order2) { create(:order, order_cycle: order_cycle1) } # Incomplete + Linked + OC Matches
    let(:order3) { create(:order, order_cycle: order_cycle1) } # Incomplete + Not-Linked + OC Matches
    let(:order4) { create(:order, order_cycle: order_cycle2) } # Incomplete + Linked + OC Mismatch

    before do
      standing_order1.orders = [order1,order2]
      standing_order2.orders = [order4]
    end

    it "only returns incomplete orders in the relevant order cycle that are linked to a standing order" do
      orders = job.send(:orders)
      expect(orders).to include order2
      expect(orders).to_not include order1, order3, order4
    end
  end

  describe "processing an order containing items with insufficient stock" do
    let(:order) { create(:order, order_cycle: order_cycle1) }
    let(:variant1) { create(:variant, count_on_hand: 5) }
    let(:variant2) { create(:variant, count_on_hand: 2) }
    let(:variant3) { create(:variant, count_on_hand: 0) }
    let(:line_item1) { create(:line_item, order: order, variant: variant1, quantity: 5) }
    let(:line_item2) { create(:line_item, order: order, variant: variant2, quantity: 2) }
    let(:line_item3) { create(:line_item, order: order, variant: variant3, quantity: 0) }

    before do
      Spree::Config.set(:allow_backorders, false)
      line_item1.update_attribute(:quantity, 3)
      line_item2.update_attribute(:quantity, 3)
      line_item3.update_attribute(:quantity, 3)
    end

    it "caps quantity at the stock level, and reports the change" do
      changes = job.send(:cap_quantity_and_store_changes, order.reload)
      expect(line_item1.reload.quantity).to be 3 # not capped
      expect(line_item2.reload.quantity).to be 2 # capped
      expect(line_item3.reload.quantity).to be 0 # capped
      expect(changes[line_item2.id]).to be 3
      expect(changes[line_item3.id]).to be 3
    end
  end

  describe "processing a standing order order" do
    let(:changes) { {} }

    before do
      form = StandingOrderForm.new(standing_order1)
      form.send(:initialise_orders!)
      expect_any_instance_of(Spree::Payment).to_not receive(:process!)
      allow(job).to receive(:cap_quantity_and_store_changes) { changes }
      allow(job).to receive(:send_placement_email).and_call_original
    end

    it "moves orders to completion, but does not process the payment" do
      order = standing_order1.orders.first
      ActionMailer::Base.deliveries.clear
      expect{job.send(:process, order)}.to change{order.reload.completed_at}.from(nil)
      expect(order.completed_at).to be_within(5.seconds).of Time.now
      expect(order.payments.first.state).to eq "checkout"
    end

    it "sends only a placement email, no confirmation emails" do
      order = standing_order1.orders.first
      ActionMailer::Base.deliveries.clear
      expect{job.send(:process, order)}.to_not enqueue_job ConfirmOrderJob
      expect(job).to have_received(:send_placement_email).with(order, changes).once
      expect(ActionMailer::Base.deliveries.count).to be 1
    end
  end
end