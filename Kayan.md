# Business Management SaaS

## Final Final Software Requirements Specification (SRS)

**Version:** 3.0
**Status:** Final
**Target Market:** Egypt
**Primary Language:** Arabic RTL
**Primary Currency:** EGP
**Architecture:** Multi-Tenant, Modular SaaS

---

# 1. Product Overview

The product is a cloud-based, multi-tenant Business Management SaaS designed primarily for small and medium-sized businesses.

The system replaces fragmented workflows based on:

* Excel files
* Paper records
* WhatsApp
* Manual calculations
* Separate inventory records
* Separate customer/supplier debt records
* Manual profit calculations
* Unconnected cash records

The system provides one centralized platform where a business transaction is entered once and all related financial, inventory, customer, supplier, treasury, and reporting effects are calculated automatically.

The system is **not limited to accounting**.

It is a complete operational Business Management System with modular functionality.

---

# 2. Product Vision

The core product philosophy is:

> **Enter the business transaction once. The system handles its consequences everywhere else.**

For example:

When a sales invoice is created:

* Sales increase
* Inventory decreases
* Customer debt increases if the sale is on credit
* Treasury increases if paid immediately
* Cost of goods sold is calculated
* Invoice profit is calculated
* Product-level profit is calculated
* Sales representative commission can be calculated
* Reports are updated automatically

The user should never need to manually enter the same transaction into multiple places.

---

# 3. Problem Statement

Many Egyptian small businesses manage operations using disconnected tools.

Typical problems include:

* Sales stored in Excel
* Purchases stored somewhere else
* Customer debts tracked manually
* Supplier debts tracked manually
* Inventory calculated separately
* Expenses recorded without categorization
* Profit calculated manually
* Sales representative commissions calculated separately
* Cash collections not connected to invoices
* Partner withdrawals not clearly separated
* Returns not correctly reflected in balances
* No reliable real-time business position
* Multiple employees entering conflicting information

The system solves these problems by creating a centralized transaction-based business system.

---

# 4. Product Goals

The product must:

1. Centralize business operations.
2. Support multiple companies.
3. Isolate each company's data completely.
4. Allow each company to activate only the modules it needs.
5. Automatically calculate financial consequences of transactions.
6. Maintain accurate inventory.
7. Track customer and supplier balances.
8. Track cash and treasury.
9. Calculate invoice and item-level profitability.
10. Calculate gross and net profit.
11. Track sales representatives and compensation.
12. Track partner withdrawals.
13. Provide business dashboards and reports.
14. Support Arabic RTL as the primary interface.
15. Be secure and production-ready.
16. Be scalable for future languages, currencies, and markets.

---

# 5. Target Market

Initial target:

* Small businesses
* Medium businesses
* Distribution companies
* Trading companies
* Retail businesses
* Wholesale businesses
* Companies with sales representatives
* Businesses managing inventory
* Businesses with customer credit
* Businesses dealing with suppliers

Initial geographic market:

**Egypt**

Initial currency:

**EGP**

Future expansion must support:

* Additional currencies
* Additional languages
* Additional countries
* Country-specific configurations

---

# 6. Target Users

## 6.1 Business Owner

Needs:

* Dashboard
* Sales
* Profit
* Customer debts
* Supplier debts
* Inventory value
* Treasury
* Expenses
* Partner withdrawals
* Overall business position
* Reports

## 6.2 Accountant / Finance User

Needs:

* Purchases
* Sales
* Collections
* Supplier payments
* Expenses
* Treasury
* Profit calculations
* Financial reports
* Reconciliation
* Audit trail

## 6.3 Sales Representative

Needs:

* Assigned customers
* Sales invoices
* Collections
* Commission
* Compensation information

## 6.4 Warehouse User

Needs:

* Inventory
* Warehouses
* Stock movements
* Purchases
* Sales
* Returns
* Stock balances

## 6.5 Administrator

Needs:

* Users
* Roles
* Permissions
* Company settings
* Modules
* Audit logs
* System configuration

---

# 7. Core Product Principles

The system must follow these principles:

### Principle 1: Single Source of Truth

A business transaction must have one authoritative record.

### Principle 2: Automatic Consequences

Related balances must be updated automatically.

### Principle 3: No Duplicate Data Entry

Users should not enter the same financial effect manually in multiple places.

### Principle 4: Historical Integrity

Completed transactions must preserve their historical meaning.

### Principle 5: Tenant Isolation

One company must never access another company's data.

### Principle 6: Modular Architecture

Companies can activate only the modules they need.

### Principle 7: Auditability

Important business changes must be traceable.

### Principle 8: Arabic-First UX

The initial UI must be designed for Arabic RTL usage.

---

# 8. Multi-Tenant Architecture

The application is a SaaS platform serving multiple independent companies.

Each company is a separate tenant.

Every tenant-owned record must contain a tenant/company reference.

Examples:

* Products
* Customers
* Suppliers
* Warehouses
* Invoices
* Expenses
* Treasury transactions
* Users
* Reports
* Sales representatives

must belong to a specific company.

Cross-tenant access must be impossible through:

* UI
* API
* Database queries
* Direct requests
* Manipulated IDs

PostgreSQL Row Level Security must be used where applicable.

---

# 9. Modular Architecture

The platform must support modules that can be enabled or disabled per company.

Potential modules:

* Sales
* Purchases
* Customers
* Suppliers
* Inventory
* Warehouses
* Expenses
* Treasury
* Sales Representatives
* Partners
* Offers
* Reports

The architecture must not assume that every company uses every module.

---

# 10. Organization Onboarding

When a company creates an account, onboarding should collect:

* Company name
* Business type
* Country
* Currency
* Language
* Basic contact information
* Initial configuration

The user then selects the required modules.

Example:

```text
What do you want to manage?

[✓] Sales
[✓] Customers
[✓] Inventory
[✓] Purchases
[✓] Suppliers
[✓] Expenses
[✓] Treasury
[✓] Sales Representatives
[ ] Partners
[ ] Offers
```

The interface must use modern selectable cards/checkboxes rather than a technical configuration screen.

---

# 11. Module Configuration

When a module is disabled:

* It should not appear in navigation.
* Its UI should not be accessible.
* Its API operations should be blocked.
* Related actions should not be available.

Module configuration must therefore be enforced at both:

**Frontend + Backend**

Frontend hiding alone is not sufficient.

---

# 12. Authentication

The system must support:

* Sign up
* Login
* Logout
* Password reset
* Session management
* Email verification where required
* Secure authentication

Authentication must be tenant-aware.

---

# 13. Organizations

Each organization represents one business/company.

Organization data includes:

* ID
* Name
* Country
* Currency
* Language
* Enabled modules
* Created date
* Settings

All business records must belong to an organization.

---

# 14. Users, Roles & Permissions

The system must support role-based access control.

Example roles:

* Owner
* Admin
* Accountant
* Sales
* Warehouse
* Custom role

Permissions must support granular operations such as:

* View
* Create
* Edit
* Delete
* Approve
* Export
* Manage settings
* View financial information

Sensitive financial information must be permission-controlled.

---

# 15. Customers

The customer module must support:

* Customer creation
* Customer editing
* Customer details
* Contact information
* Customer type
* Credit status
* Transaction history
* Current balance
* Sales history
* Returns
* Collections

Customer balance must be calculated from actual transactions.

---

# 16. Suppliers

The supplier module must support:

* Supplier creation
* Supplier editing
* Supplier details
* Purchase history
* Supplier balance
* Payments
* Returns
* Transaction history

---

# 17. Products

Each company must have its own product catalog.

Products must support:

* Product name
* SKU/code
* Category
* Unit
* Cost information
* Selling price
* Multiple price levels where required
* Active/inactive status
* Inventory tracking
* Company ownership

Products from one company must never appear in another company's catalog.

---

# 18. Product Pricing

The system must support company-specific product pricing.

Each company can define:

* Product
* Selling price
* Cost
* Optional price lists
* Effective pricing
* Discounts

The system must never assume a global selling price shared between companies.

Future support may include:

* Wholesale price
* Retail price
* Customer-specific price
* Promotional price

---

# 19. Warehouses

The system must support multiple warehouses.

Each warehouse has:

* Name
* Location
* Status
* Company ownership

Inventory must be tracked by warehouse.

The system must support:

* Stock balance
* Stock movements
* Sales
* Purchases
* Returns
* Transfers where applicable

---

# 20. Inventory Management

Inventory must automatically change based on business transactions.

### Purchase

Increases inventory.

### Sale

Decreases inventory.

### Sales Return

Increases inventory.

### Purchase Return

Decreases inventory.

Inventory quantities must be transaction-driven.

Manual stock editing must be restricted and audited.

---

# 21. Inventory Costing

The recommended initial costing method is:

**Weighted Average Cost**

Example:

```text
100 units × 100 EGP
100 units × 120 EGP
```

Average cost:

```text
(10,000 + 12,000) / 200
= 110 EGP
```

The system then uses the applicable cost to calculate Cost of Goods Sold.

The business must confirm whether Weighted Average Cost or another accounting method such as FIFO should be used before final accounting implementation.

---

# 22. Purchase Invoices

The system must allow users to create purchase invoices containing:

* Supplier
* Date
* Invoice number
* Warehouse
* Products
* Quantities
* Purchase prices
* Discounts
* Taxes if enabled
* Total
* Payment status
* Notes

Creating a purchase invoice must:

* Increase inventory
* Increase supplier payable if unpaid
* Increase treasury if paid immediately
* Update inventory cost
* Update supplier balance
* Record the transaction

---

# 23. Supplier Payments

Users must be able to record payments to suppliers.

Each payment includes:

* Supplier
* Date
* Amount
* Payment method
* Treasury account
* Reference
* Notes

Supplier balance:

```text
Supplier Payable
=
Purchases
- Payments
- Purchase Returns
```

The system must show:

* Total supplier debt
* Paid amount
* Remaining amount

---

# 24. Sales Invoices

The system must support sales invoices containing:

* Customer
* Date
* Invoice number
* Warehouse
* Sales representative
* Products
* Quantities
* Selling prices
* Discounts
* Payment status
* Notes

Creating a sales invoice must automatically:

* Decrease inventory
* Calculate sales value
* Calculate cost
* Calculate profit
* Increase customer receivable for credit sales
* Increase treasury for immediate payment
* Update reports
* Record the sales representative

---

# 25. Invoice-Level Profitability

Invoice-level profitability is a **mandatory MVP requirement**.

For every sales invoice:

```text
Invoice Profit
=
Net Sales
-
COGS
```

Profit margin:

```text
Profit Margin %
=
Invoice Profit / Net Sales × 100
```

Example:

```text
Net Sales = 4,500 EGP
COGS = 3,300 EGP

Profit = 1,200 EGP

Margin = 26.67%
```

The invoice detail page must display:

* Gross sales
* Discounts
* Net sales
* Cost
* Profit
* Profit margin

---

# 26. Invoice Item-Level Profitability

Profitability must also be available for every invoice line.

Each invoice item must be able to show:

* Product
* Quantity
* Selling price
* Sales value
* Unit cost
* Cost value
* Profit
* Profit margin

Example:

```text
Product A
Quantity: 10
Selling Price: 150
Unit Cost: 100

Sales = 1,500
Cost = 1,000
Profit = 500
```

This is required because aggregate invoice profit alone is insufficient for understanding product performance.

---

# 27. Sales Returns

The system must support returns from customers/market.

A return must reference the original sale where possible.

Return processing must:

* Increase inventory
* Reduce customer receivable
* Reduce recognized sales
* Reverse the applicable cost
* Reverse the applicable profit
* Maintain transaction history

Example:

```text
Original Sale:
Customer owes 10,000

Return:
2,000

New customer balance:
8,000
```

Returned inventory must be reflected in the correct warehouse.

---

# 28. Customer Collections

The system must allow recording customer payments/collections.

Each collection contains:

* Customer
* Date
* Amount
* Payment method
* Treasury destination
* Reference
* Notes

Customer balance:

```text
Customer Receivable
=
Sales
- Collections
- Returns / Credits
```

Collections must automatically affect the treasury.

---

# 29. Expenses

The system must support recording business expenses.

Each expense includes:

* Expense category
* Amount
* Date
* Payment method
* Treasury account
* Description
* Optional attachment
* Responsible user

Expenses reduce treasury when paid.

Expenses must be categorized.

---

# 30. Expense Categories

The business must be able to define expense types.

Examples:

* Transportation
* Salaries
* Rent
* Electricity
* Internet
* Maintenance
* Marketing
* Office expenses
* Other

Categories should be configurable per company.

---

# 31. Treasury / Cashbox

The treasury module represents company cash balances.

The system must support:

### Money In

* Customer collections
* Cash sales
* Other income

### Money Out

* Supplier payments
* Expenses
* Partner withdrawals
* Other approved payments

The system must maintain a running treasury balance.

Every treasury movement must reference its source transaction.

---

# 32. Sales Representatives

The system must support sales representatives.

A representative can have:

* Name
* Contact information
* Assigned customers
* Sales
* Collections
* Commission rules
* Salary
* Transportation allowance
* Other compensation information

Sales representatives must be linked to sales invoices where applicable.

---

# 33. Representative Compensation

The system must support:

* Fixed salary
* Commission
* Transportation allowance
* Other approved compensation

The business must be able to configure how commission is calculated.

Possible commission bases:

* Sales value
* Net sales
* Gross profit
* Collected amount

The exact commission basis must be confirmed by the business before final implementation.

Representative salary, commission, and transportation allowance must be reflected in expenses according to the company's accounting treatment.

---

# 34. Partner Withdrawals

The system must support recording physical withdrawals by business partners.

Each withdrawal contains:

* Partner
* Date
* Amount
* Treasury
* Description
* Notes

Partner withdrawals must be tracked separately from operating expenses.

They must not automatically reduce operating profit unless the business's accounting policy explicitly requires another treatment.

---

# 35. Monthly Market Offers

The system must support monthly offers/promotions for the market.

The exact business definition of "monthly market offers" must be confirmed.

The module should be designed to potentially support:

* Offer name
* Customer/market
* Start date
* End date
* Products
* Promotional prices
* Discount
* Quantity conditions
* Offer status

The implementation must be based on the confirmed business workflow.

---

# 36. Sales & Revenue

The system must calculate:

* Total sales
* Gross sales
* Discounts
* Returns
* Net sales
* Sales by period
* Sales by customer
* Sales by product
* Sales by representative
* Sales by invoice

Net sales should account for applicable returns and discounts.

---

# 37. Gross Profit

Gross profit:

```text
Gross Profit
=
Net Sales
-
Cost of Goods Sold
```

The system must support gross profit reporting by:

* Invoice
* Product
* Customer
* Representative
* Date
* Period

---

# 38. Net Profit

Net profit:

```text
Net Profit
=
Gross Profit
-
Operating Expenses
```

The system must distinguish operating expenses from:

* Customer collections
* Supplier payments
* Partner withdrawals
* Other balance-sheet movements

The exact accounting treatment of taxes and non-operating items must be configurable/finalized with the business/accountant.

---

# 39. Customer & Supplier Balances

## Customer Balance

```text
Sales
- Collections
- Returns / Credits
=
Customer Receivable
```

## Supplier Balance

```text
Purchases
- Payments
- Purchase Returns
=
Supplier Payable
```

The system must provide transaction-level details supporting every balance.

---

# 40. Financial Position

The system must provide a high-level view of the business's financial position.

A conceptual calculation is:

```text
Inventory Value
+
Customer Receivables
+
Cash / Bank
+
Other Assets
-
Supplier Payables
-
Other Liabilities
=
Net Business Position
```

This is a management/business-position metric unless formally defined otherwise by the company's accountant.

The system must not automatically assume that this metric is identical to formal accounting "Owner's Equity" or statutory balance-sheet equity.

---

# 41. رأس المال العام

The system must explicitly support the business owner's requested concept of:

**رأس المال العام**

The initial business definition proposed for confirmation is:

```text
رأس المال العام
=
إجمالي أرصدة المخازن
+
مديونية السوق / العملاء
+
الأرصدة النقدية
-
مديونية الموردين
-
ما على الشركة من التزامات
```

The system should present the underlying components separately so the owner can understand how the number was calculated.

Example:

```text
قيمة المخزون              500,000
مديونية السوق             300,000
الخزنة والبنوك             200,000
---------------------------------
الإجمالي                   1,000,000

مديونية الموردين          250,000
التزامات أخرى              50,000
---------------------------------

رأس المال العام            700,000
```

### Important Accounting Clarification

The term "رأس المال العام" is a business-owner terminology and must not automatically be treated as formal accounting "Owner's Equity" or "Paid-in Capital".

The exact definition must be confirmed with the business owner/accountant before the final accounting implementation.

---

# 42. Dashboard

The main dashboard should provide a real-time business overview.

Primary cards:

```text
إجمالي المبيعات
صافي المبيعات
إجمالي الربح
صافي الربح
فلوس عند العملاء
فلوس للموردين
قيمة المخزون
رصيد الخزنة
```

Additional information:

* Sales chart
* Profit chart
* Expenses
* Collections
* Supplier payments
* Top products
* Top customers
* Sales representative performance
* Recent transactions

The dashboard must adapt according to enabled modules.

---

# 43. Reports

The reporting system must support:

## Sales

* Sales by date
* Sales by invoice
* Sales by customer
* Sales by product
* Sales by representative

## Profit

* Profit per invoice
* Profit per item
* Profit per product
* Profit per customer
* Profit per representative
* Gross profit
* Net profit
* Margin

## Inventory

* Current stock
* Inventory value
* Stock movements
* Product quantities
* Warehouse balances

## Customers

* Customer balances
* Customer transaction history
* Collections
* Returns

## Suppliers

* Supplier balances
* Supplier purchases
* Payments
* Returns

## Treasury

* Cash movements
* Collections
* Payments
* Expenses
* Withdrawals
* Current balance

## Financial Position

* Inventory
* Receivables
* Cash
* Payables
* Other liabilities
* Net business position
* رأس المال العام according to the confirmed business formula

---

# 44. Search & Filtering

The system must provide global and module-specific search.

Users should be able to search/filter by:

* Name
* Invoice number
* Product
* Customer
* Supplier
* Representative
* Date
* Status
* Warehouse
* Amount

Date filtering should support:

* Today
* This week
* This month
* Custom range

---

# 45. Notifications & Alerts

The system may provide notifications for:

* Customer debt due
* Supplier payment due
* Low inventory
* Outstanding collections
* Large expenses
* Failed transactions
* Important system events

Notifications must respect user permissions.

---

# 46. Audit Logging

Important actions must be recorded.

Examples:

* Invoice creation
* Invoice modification
* Invoice cancellation
* Return creation
* Payment
* Collection
* Expense
* Partner withdrawal
* Product price change
* Permission change
* User creation
* User deletion
* Configuration change

Audit logs should contain:

* User
* Action
* Record
* Timestamp
* Relevant before/after information where appropriate

---

# 47. Financial Integrity

Financial records must not be casually deleted.

For completed transactions, the preferred approach is:

* Cancellation
* Reversal
* Correction transaction
* Audit trail

rather than destructive deletion.

The system must prevent inconsistent balances.

---

# 48. Historical Data Integrity

Historical transactions must preserve the correct historical values.

Example:

If a product's current selling price changes from:

```text
100 → 120
```

an old invoice sold at:

```text
100
```

must continue showing:

```text
100
```

It must not dynamically change to the new price.

Similarly, historical costs used for profitability must remain consistent with the transaction's accounting data.

---

# 49. Concurrency & Idempotency

The backend must protect against:

* Duplicate submissions
* Double payments
* Double collections
* Concurrent invoice creation
* Race conditions
* Duplicate stock movements

Financial transactions must be atomic.

A transaction must either complete fully or fail without partially updating the system.

---

# 50. Security Requirements

Security is a production requirement.

The system must implement:

* Tenant isolation
* PostgreSQL RLS where applicable
* Server-side authorization
* Input validation
* Authentication
* Secure session handling
* Secure secrets
* HTTPS
* Protection against unauthorized API access
* Protection against IDOR
* Protection against injection
* Protection against privilege escalation

Sensitive server credentials must never be exposed to the browser.

Supabase service-role credentials must remain server-side.

---

# 51. Database Architecture

Recommended database:

**PostgreSQL / Supabase**

Core entities include:

```text
organizations
users
roles
permissions
organization_users

customers
suppliers

products
product_categories
product_prices

warehouses
inventory_movements
inventory_balances

purchase_invoices
purchase_invoice_items
supplier_payments

sales_invoices
sales_invoice_items
sales_returns
sales_return_items

customer_collections

expense_categories
expenses

treasury_accounts
treasury_transactions

sales_representatives
representative_compensation

partners
partner_withdrawals

offers

audit_logs
```

The exact schema may evolve during implementation.

---

# 52. API / Backend Architecture

Backend logic must be transaction-oriented.

Business rules must not depend only on frontend calculations.

For example, when creating a sales invoice, the backend must validate:

* Organization
* User permissions
* Customer
* Product
* Warehouse
* Stock
* Prices
* Quantities
* Financial totals
* Representative
* Payment
* Treasury effects

The server must calculate authoritative financial values.

---

# 53. Frontend Architecture

Recommended stack:

* Next.js
* React
* TypeScript
* Tailwind CSS
* shadcn/ui
* React Hook Form
* Zod
* Recharts

The UI must be:

* Responsive
* Arabic RTL
* Fast
* Clean
* Modern
* Business-oriented
* Easy for non-technical users

---

# 54. UI / UX Requirements

The UI should feel like a modern SaaS product, not an old accounting application.

Primary navigation example:

```text
الرئيسية

المبيعات
 ├─ فواتير البيع
 ├─ المرتجعات
 └─ التحصيل

المشتريات
 ├─ فواتير الشراء
 └─ المدفوعات

العملاء

الموردين

المخزون

المصروفات

الخزنة

المندوبين

الشركاء

التقارير

المستخدمين والصلاحيات

الإعدادات
```

Disabled modules must not appear.

---

# 55. File Attachments

The system may support attachments for:

* Invoices
* Expenses
* Supplier documents
* Customer documents
* Payments
* Other business records

Storage must be tenant-isolated and permission-controlled.

---

# 56. Import / Export

The system should support:

### Import

* Products
* Customers
* Suppliers
* Opening balances
* Inventory
* Other supported master data

CSV/Excel imports must include validation and error reporting.

### Export

Reports should support:

* CSV
* Excel
* PDF where appropriate

Exports must respect permissions and tenant isolation.

---

# 57. Performance Requirements

The system should provide responsive interaction for normal business operations.

Targets:

* Fast dashboard loading
* Paginated lists
* Server-side filtering
* Efficient database queries
* Proper indexes
* No unnecessary full-table queries

Large reports must use optimized queries and pagination where appropriate.

---

# 58. Observability & Error Handling

The system must provide:

* Structured error handling
* Server-side logs
* Client error reporting where appropriate
* Database error monitoring
* Failed transaction tracking
* Meaningful user-facing error messages

Technical errors should not expose sensitive internal information.

---

# 59. Testing Strategy

Testing must include:

## Unit Tests

For:

* Profit calculations
* Margins
* Customer balances
* Supplier balances
* Inventory calculations
* Treasury calculations
* Commission calculations

## Integration Tests

For complete transaction flows.

Example:

```text
Purchase
→ Inventory Increase
→ Supplier Debt

Sale
→ Inventory Decrease
→ Customer Debt
→ COGS
→ Profit

Collection
→ Customer Debt Decrease
→ Treasury Increase

Return
→ Inventory Increase
→ Customer Debt Decrease
→ Profit Reversal
```

## E2E Tests

At minimum:

* Organization creation
* Module configuration
* Login
* Product creation
* Customer creation
* Supplier creation
* Purchase invoice
* Sales invoice
* Collection
* Supplier payment
* Return
* Expense
* Partner withdrawal
* Reports
* Tenant isolation

---

# 60. Backup & Recovery

Production deployment must include:

* Database backups
* Backup retention
* Recovery procedure
* Recovery testing
* Disaster recovery planning

The business must understand the expected:

* RPO
* RTO

before production launch.

---

# 61. Deployment & Infrastructure

Recommended stack:

* Vercel for frontend/application hosting
* Supabase/PostgreSQL
* Supabase Auth
* Supabase Storage
* GitHub
* GitHub Actions

Production environment must separate:

* Development
* Testing
* Production

Secrets must be stored securely.

---

# 62. Development Standards

The codebase must follow:

* TypeScript strictness
* Clear naming
* Reusable components
* Modular architecture
* Server/client separation
* Validation
* Error handling
* Database migrations
* Automated testing
* Code review

Business logic must not be duplicated unnecessarily between frontend and backend.

---

# 63. AI Coding Agent Rules

If AI coding agents are used, they must follow strict rules.

The AI agent must:

1. Understand the existing architecture before modifying it.
2. Never invent database structures without checking the schema.
3. Never bypass authentication.
4. Never disable RLS as a shortcut.
5. Never expose secrets.
6. Never modify financial calculations without understanding dependencies.
7. Preserve existing functionality.
8. Run tests after significant changes.
9. Explain risky migrations.
10. Avoid destructive database operations unless explicitly approved.
11. Keep tenant isolation intact.
12. Preserve historical financial records.
13. Avoid unnecessary rewrites.
14. Verify production impact before changing core business logic.

---

# 64. Implementation Phases

## Phase 1: Foundation

* Authentication
* Organizations
* Users
* Roles
* Modules
* Settings
* RTL foundation

## Phase 2: Master Data

* Customers
* Suppliers
* Products
* Categories
* Warehouses
* Product pricing

## Phase 3: Purchases & Inventory

* Purchase invoices
* Supplier balances
* Supplier payments
* Inventory
* Costing

## Phase 4: Sales

* Sales invoices
* Customers
* Collections
* Returns
* Invoice profitability
* Item profitability

## Phase 5: Financial Operations

* Expenses
* Expense categories
* Treasury
* Sales representatives
* Compensation
* Partner withdrawals

## Phase 6: Reporting

* Dashboard
* Sales reports
* Profit reports
* Inventory reports
* Customer reports
* Supplier reports
* Treasury reports
* Financial position
* رأس المال العام

## Phase 7: Production Hardening

* Security audit
* Performance optimization
* Automated testing
* Backup/recovery
* Monitoring
* Deployment
* Production readiness

---

# 65. Business Decisions Requiring Confirmation

The following must be confirmed with the business owner/accountant before final implementation of the corresponding rules:

### 1. Inventory Costing

Choose:

* Weighted Average
* FIFO
* Other

### 2. Profit After Discounts

Confirm whether discounts reduce:

* Revenue
* Profit
* Commission basis
* All applicable calculations

### 3. Returns

Confirm treatment of:

* Damaged goods
* Resalable goods
* Partial returns
* Historical cost

### 4. Monthly Offers

Clarify exactly what "العروض الشهرية للسوق" means operationally.

### 5. Commission

Confirm whether commission is based on:

* Gross sales
* Net sales
* Collected sales
* Gross profit

### 6. Financial Position

Confirm the exact definition of:

**صافي المركز المالي**

### 7. رأس المال العام

Confirm that the business intends:

```text
Inventory
+
Customer Receivables
+
Cash/Bank
-
Supplier Payables
-
Other Company Liabilities
```

to represent the requested "رأس المال العام".

This must not be automatically equated to formal accounting equity without professional confirmation.

---

# 66. Definition of Done

A feature is considered complete only when:

* UI exists
* Backend logic exists
* Database logic exists
* Permissions are enforced
* Validation exists
* Error handling exists
* Relevant financial/inventory effects work
* Audit logging exists where required
* Tests exist
* Tenant isolation is verified
* RTL is correct
* Historical integrity is preserved

---

# 67. Production Readiness Gate

Before production launch:

### Security

* Authentication tested
* Authorization tested
* RLS tested
* Tenant isolation tested
* Secrets reviewed
* API security reviewed

### Financial Integrity

* Sales tested
* Purchases tested
* Returns tested
* Collections tested
* Supplier payments tested
* Expenses tested
* Treasury tested
* Profit tested
* Inventory tested
* Customer balances tested
* Supplier balances tested
* رأس المال العام calculation verified

### Reliability

* Backups configured
* Recovery tested
* Monitoring configured
* Error handling verified

### Performance

* Database indexes reviewed
* Slow queries investigated
* Dashboard tested
* Reports tested with realistic data

### UX

* Arabic RTL reviewed
* Mobile/responsive behavior reviewed
* Empty states reviewed
* Error states reviewed
* Loading states reviewed

---

# 68. Final MVP Scope

The MVP must include:

### Core

* Multi-tenancy
* Authentication
* Organizations
* Users
* Roles
* Permissions
* Module configuration

### Master Data

* Customers
* Suppliers
* Products
* Product prices
* Warehouses

### Sales

* Sales invoices
* Invoice profitability
* Item profitability
* Returns
* Collections

### Purchases

* Purchase invoices
* Supplier payments
* Supplier balances

### Inventory

* Stock
* Stock movements
* Inventory value
* Costing

### Finance

* Expenses
* Expense categories
* Treasury
* Sales representative compensation
* Partner withdrawals

### Reporting

* Sales
* Profit
* Inventory
* Customer balances
* Supplier balances
* Treasury
* Financial position
* رأس المال العام

### Platform

* Arabic RTL
* EGP
* Audit logs
* Security
* Testing
* Backups
* Production infrastructure

---

# 69. Future Scope

Potential future features:

* Mobile applications
* Customer portal
* Supplier portal
* Advanced CRM
* Purchasing workflows
* Approval workflows
* Advanced promotions
* Barcode scanning
* POS
* Payment gateway integration
* Banking integration
* WhatsApp integration
* Advanced analytics
* AI business insights
* Demand forecasting
* Multi-country support
* Multi-currency
* Advanced accounting
* Tax integrations
* Payroll
* Manufacturing
* Advanced warehouse management

These are not required for the initial MVP unless explicitly approved.

---

# 70. Final Product Philosophy

The system must behave as a **Business Management OS**, not simply an accounting application.

The central rule is:

> **The user records the business event once. The system automatically maintains the consequences.**

For example:

```text
SALE
 ↓
Inventory decreases
 ↓
Customer balance updates
 ↓
Treasury updates if paid
 ↓
COGS calculated
 ↓
Invoice profit calculated
 ↓
Product profit calculated
 ↓
Representative commission calculated
 ↓
Reports update
 ↓
Financial position updates
 ↓
رأس المال العام updates
```

Likewise:

```text
COLLECTION
 ↓
Customer debt decreases
 ↓
Treasury increases
 ↓
Customer balance updates
 ↓
Financial position updates
```

And:

```text
RETURN
 ↓
Inventory increases
 ↓
Customer debt decreases
 ↓
Sales reverse
 ↓
Cost reverses
 ↓
Profit reverses
 ↓
Reports update
```

The product should make the business owner feel that the entire business is connected.

The user should **not** need to understand accounting mechanics to operate the system correctly.

The system should transform business transactions into the required financial, inventory, and operational consequences automatically.

## Final Principle

> **One transaction. One entry. All consequences handled automatically.**

---

## Phase 22–26 — Discounts, Bonus, net pricing, rep targets, analysis reports

**One engine.** `_pricing()` (database) computes every invoice: line discounts, invoice discount, cash
discount, tiered discount and bonus. The sales RPC, the purchase RPC and the screen preview
(`pricing_preview`) all call it, so the screen always matches what is posted.

| Piece | Rule |
|---|---|
| Invoice discount | optional, EGP, entered per invoice |
| Cash discount | optional, EGP; applied **only** when the payment method is Cash and something is collected/paid now (`is_cash_payment`) |
| Tiered discount | Settings → «الخصومات والـBonus». Highest tier whose minimum ≤ invoice value (after line discounts) applies; tiers don't stack |
| Bonus | rules «buy ≥ X of A → get Y of B», repeating by default. Same product → folded into the line; other product → own zero-revenue line. Stock and COGS always move |
| `discount_total` | total of all discount types, so `net = subtotal − discount_total` everywhere |
| Net unit price | `net_total / (quantity + bonus_quantity)` stored per item (`effective_unit_price` / `effective_unit_cost`); invoice-level discounts are allocated pro-rata, last line absorbs rounding |
| Returns | partial or full; value = net price, last units take the exact remainder; resalable stock returns at historical cost |
| Sales notes | plain text, never read by any calculation |

**Reps.** Monthly target + minimum target for commission. A month's commission is earned only if that
month's net sales (after discounts and returns) reach the minimum. `invoice_commissions.earned_commission`
is the single commission number used by P&L, reports and rep screens. Salaries / rep expenses reduce
profit and treasury; commission payouts reduce treasury only (already deducted from profit when earned).

**Rep isolation.** A member with the Sales Representative role who is linked to a representative record
(Representatives → linked user) sees only their customers, invoices, collections, returns and notes.
Enforced by RESTRICTIVE RLS policies, so the report functions (security invoker) are scoped for free.

**Reports.** `report_customer_debts`, `report_supplier_debts`, `report_customer_analysis`,
`report_supplier_analysis`, `report_rep_overview`, `report_rep_analysis` — all read the same views the
posting code maintains (`customer_balances`, `supplier_balances`, `rep_monthly_performance`,
`rep_commission_balances`). Tests 90–92 assert they agree to the cent.

**Cost & profit are protected in the database (Phase 27).** Invoice/item/return cost and profit live in
`sales_*_financials` tables readable only with `view_financial` and never by a restricted rep. Reports and
dashboards read through the `v_sales_*` views (security invoker) that rejoin them; postings write them inside
the same RPCs. Stock average cost, stock movements, transfers and the product cost price are blocked for
restricted reps, who get selling prices from the `product_sale_prices` view. If you add a column to one of the
four base sales tables, recreate its `v_sales_*` view (they use `select base.*`).
