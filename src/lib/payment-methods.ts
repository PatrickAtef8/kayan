// The payment method only records HOW the money came in. It never changes a discount:
// the immediate-payment discount depends on paying NOW (an amount paid on the invoice),
// whatever the method.
export const PAYMENT_METHODS = ["نقدًا", "Visa", "InstaPay", "تحويل بنكي", "شيك", "أخرى"] as const;
export const DEFAULT_PAYMENT_METHOD = "نقدًا";
