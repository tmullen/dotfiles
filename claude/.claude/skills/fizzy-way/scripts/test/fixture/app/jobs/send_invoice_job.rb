class SendInvoiceJob < ApplicationJob
  def perform(invoice)
    invoice.lock!
    InvoiceMailer.with(invoice:).deliver_now
    invoice.update!(sent_at: Time.current)
  end
end
