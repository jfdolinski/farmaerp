import { afterAll, describe, expect, it } from 'vitest';
import { runMigrations } from '../scripts/lib.mjs';
import { asOwner, closePools, connectionConfig, ownerPool } from './helpers.mjs';

afterAll(closePools);

const EXPECTED_TABLES = [
  'abc_curve_setting', 'agreement', 'agreement_invoice', 'agreement_invoice_item', 'app_release', 'auth_event', 'biometric_consent', 'branch', 'branch_catalog_key', 'branch_certificate', 'branch_company_event',
  'branch_csc', 'branch_dfe_sync', 'branch_group', 'cash_alert', 'cash_movement', 'cash_session', 'cash_session_count', 'cashback_allocation', 'cashback_entry', 'cashback_policy',
  'catalog_manufacturer', 'catalog_product', 'catalog_product_barcode', 'catalog_product_image', 'catalog_product_pmc', 'catalog_product_tax', 'catalog_sync_run', 'catalog_tax_fetch', 'central_nfe', 'central_nfe_series', 'code_counter',
  'company', 'controlled_dispensing', 'credit_account', 'credit_account_event', 'credit_allocation', 'credit_installment', 'credit_payment', 'credit_policy', 'customer', 'customer_abc',
  'customer_abc_event', 'customer_agreement', 'customer_consent_event', 'customer_dependent', 'customer_group', 'dfe_document', 'discount_rule', 'document_import', 'document_import_note',
  'economic_group', 'face_template', 'fiscal_document', 'fiscal_event', 'fiscal_number_void', 'health_professional', 'import_pending_issuer', 'import_waiting_note', 'imported_sale',
  'imported_sale_item', 'imported_sale_payment', 'imported_stock_note', 'imported_stock_note_item', 'limit_type', 'login_image', 'nfe_correction', 'pbm_authorization', 'pbm_authorization_item', 'pbm_program', 'pbm_program_branch', 'pbm_test_rule', 'pdv_auth_event', 'pdv_cart_discard', 'pdv_customer_cache', 'permission',
  'platform_admin', 'product', 'product_barcode', 'product_barcode_channel', 'product_batch', 'product_batch_event', 'product_branch_status', 'product_catalog_event', 'product_category', 'product_cost', 'product_group',
  'product_pmc', 'product_price', 'product_rule', 'product_status_event', 'product_supplier', 'product_tax_rule', 'purchase_invoice', 'purchase_invoice_audit', 'purchase_invoice_document',
  'purchase_invoice_event', 'purchase_invoice_installment', 'purchase_invoice_item', 'purchase_invoice_item_batch', 'purchase_invoice_item_cost_release', 'purchase_invoice_summary',
  'purchase_return', 'purchase_return_item', 'purchase_return_tax_setting', 'quote', 'quote_item', 'region', 'role', 'role_limit', 'role_permission', 'rule_type', 'sale', 'sale_alert', 'sale_item',
  'sale_item_discount', 'sale_payment', 'sale_return', 'sale_return_item', 'sales_channel', 'service_invoice', 'sngpc_branch', 'sngpc_credential', 'sngpc_dispensing_complement', 'sngpc_movement',
  'sngpc_submission', 'stock_balance', 'stock_count', 'stock_count_item', 'stock_movement', 'supervisor_release', 'supplier', 'sync_change', 'sync_conflict', 'sync_receipt', 'terminal',
  'terminal_credential_delivery', 'terminal_event', 'terminal_fiscal_series', 'terminal_fiscal_series_event', 'terminal_log', 'terminal_pairing_request', 'terminal_status', 'terminal_update_event',
  'user_account', 'user_branch', 'user_credential', 'user_pin', 'user_role', 'user_session',
];

async function publicTables() {
  const { rows } = await ownerPool.query(`
    SELECT c.oid, c.relname, c.relrowsecurity
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
     ORDER BY c.relname`);
  return rows;
}

describe('migrations', () => {
  it('não aplicam nada na segunda execução', async () => {
    const applied = await runMigrations(
      connectionConfig('farmaerp_migrator', process.env.FARMAERP_MIGRATOR_PASSWORD),
    );
    expect(applied).toEqual([]);

    const { rows } = await ownerPool.query(
      'SELECT name FROM db_migrations.applied_migrations ORDER BY name',
    );
    expect(rows.map((row) => row.name)).toEqual([
      '0001_table_standard',
      '0002_multibranch_structure',
      '0003_row_level_security',
      '0004_active_views',
      '0005_error_codes_and_trace',
      '0006_terminal_pairing',
      '0007_human_codes',
      '0008_authentication',
      '0009_roles_and_permissions',
      '0010_products',
      '0011_product_prices_and_status',
      '0012_product_rules',
      '0013_stock',
      '0014_stock_operations',
      '0015_customers',
      '0016_agreements',
      '0017_fiscal_setup',
      '0018_branch_cnpj_root',
      '0019_company_branch_admin',
      '0020_terminal_fiscal_series',
      '0021_catalog_product_tax',
      '0022_suppliers',
      '0023_purchase_invoices',
      '0024_purchase_invoice_posting',
      '0025_purchase_invoice_download',
      '0026_service_invoices',
      '0027_value_limits',
      '0028_catalog_images',
      '0029_pdv_sync_download',
      '0030_pdv_sync_upload',
      '0031_pdv_sync_monitor',
      '0032_sales',
      '0033_pdv_pin',
      '0034_pdv_sale_rules',
      '0035_controlled',
      '0036_cash_close',
      '0037_quotes',
      '0038_quote_checkout',
      '0039_sale_returns',
      '0040_return_credit', '0041_pdv_auth', '0042_face', '0043_discounts', '0044_sale_discounts', '0045_sync_retry', '0046_store_credit', '0047_store_credit_pdv', '0048_platform', '0049_cashback', '0050_cashback_pdv', '0051_agreement_invoice', '0052_sngpc_maintenance', '0053_app_release', '0054_sngpc_submission', '0055_nfce_terminal_credentials', '0056_controlled_antimicrobial_buyer', '0057_health_professional', '0058_pdv_customer_create', '0059_customer_purchase_history', '0060_nfce_document', '0061_document_import', '0062_imported_sale_queries', '0063_pdv_own_tax', '0064_nfe_import', '0065_imported_note_queries', '0066_opening_inventory', '0067_nfce_cancel_void', '0068_nfce_resend_fixes', '0069_terminal_nfce_cancel', '0070_pdv_cart_discard', '0071_import_issuer_destination', '0072_quote_merge_negative_stock', '0073_customer_abc_curve', '0074_purchase_invoice_content', '0075_terminal_fixed_seller', '0076_purchase_invoice_cancel_fraction', '0077_product_measure_unit', '0078_purchase_return', '0079_central_nfe', '0080_product_catalog_audit', '0081_login_image', '0082_platform_import', '0083_return_tax_settings', '0084_transfer_nfe', '0085_customer_company_nfe_sale', '0086_external_catalog', '0087_catalog_tax_sync', '0088_catalog_brand_department', '0089_nfe55_contingency', '0090_nfe55_sale_cancel', '0091_nfe55_cancel_terminal_central', '0092_voiding_disabled_states', '0093_alphanumeric_cnpj', '0094_nfe_correction', '0095_pbm',
    ]);
  });
});

describe('padrão de todas as tabelas', () => {
  it('contém as tabelas esperadas', async () => {
    const tables = await publicTables();
    expect(tables.map((table) => table.relname)).toEqual(EXPECTED_TABLES);
  });

  it('toda tabela tem as colunas obrigatórias com os tipos corretos', async () => {
    const expected = {
      id: 'uuid',
      created_at: 'timestamp with time zone',
      updated_at: 'timestamp with time zone',
      deleted_at: 'timestamp with time zone',
      version: 'bigint',
      updated_by: 'uuid',
      trace_id: 'uuid',
    };
    for (const table of await publicTables()) {
      const { rows } = await ownerPool.query(
        `SELECT column_name, data_type FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = $1`,
        [table.relname],
      );
      const types = Object.fromEntries(rows.map((row) => [row.column_name, row.data_type]));
      expect(types, table.relname).toMatchObject(expected);
    }
  });

  it('toda tabela tem chave primária em id, com padrão uuidv7 e CHECK de versão', async () => {
    for (const table of await publicTables()) {
      const { rows: primaryKey } = await ownerPool.query(
        `SELECT a.attname
           FROM pg_index i
           JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
          WHERE i.indrelid = $1 AND i.indisprimary`,
        [table.oid],
      );
      expect(primaryKey.map((row) => row.attname), table.relname).toEqual(['id']);

      const { rows: columns } = await ownerPool.query(
        `SELECT column_default FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = $1 AND column_name = 'id'`,
        [table.relname],
      );
      expect(columns[0].column_default, table.relname).toBe('uuidv7()');

      const { rows: checks } = await ownerPool.query(
        `SELECT 1 FROM pg_constraint WHERE conrelid = $1 AND conname = $2`,
        [table.oid, `${table.relname}_id_uuid_v7_check`],
      );
      expect(checks, table.relname).toHaveLength(1);
    }
  });

  it('toda tabela tem triggers de auditoria e de bloqueio de exclusão, e RLS ativa', async () => {
    for (const table of await publicTables()) {
      expect(table.relrowsecurity, table.relname).toBe(true);
      const { rows } = await ownerPool.query(
        `SELECT tgname FROM pg_trigger WHERE tgrelid = $1 AND NOT tgisinternal AND tgenabled = 'O'`,
        [table.oid],
      );
      expect(rows.map((row) => row.tgname), table.relname).toEqual(
        expect.arrayContaining(['audit_row', 'block_physical_delete']),
      );
    }
  });

  it('toda tabela tem política de leitura para a API', async () => {
    for (const table of await publicTables()) {
      const { rows } = await ownerPool.query(
        `SELECT 1 FROM pg_policies
          WHERE schemaname = 'public' AND tablename = $1 AND cmd = 'SELECT'
            AND 'farmaerp_app' = ANY (roles)`,
        [table.relname],
      );
      expect(rows, table.relname).toHaveLength(1);
    }
  });

  it('apply_table_standard recusa tabela sem as colunas obrigatórias', async () => {
    await asOwner(async (client) => {
      await client.query('CREATE TABLE incomplete_table (id uuid PRIMARY KEY)');
      await expect(
        client.query(`CALL app.apply_table_standard('public.incomplete_table')`),
      ).rejects.toThrow(/colunas obrigatórias: created_at, updated_at, deleted_at, version, updated_by, trace_id/);
    });
  });
});

describe('papel da API', () => {
  it('não é superusuário, não ignora RLS e não cria objetos', async () => {
    const { rows } = await ownerPool.query(
      `SELECT rolsuper, rolbypassrls, rolcreatedb, rolcreaterole
         FROM pg_roles WHERE rolname = 'farmaerp_app'`,
    );
    expect(rows[0]).toEqual({
      rolsuper: false,
      rolbypassrls: false,
      rolcreatedb: false,
      rolcreaterole: false,
    });
  });

  it('não é dono de nenhuma tabela ou view', async () => {
    const { rows } = await ownerPool.query(`
      SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public'
         AND pg_get_userbyid(c.relowner) = 'farmaerp_app'`);
    expect(rows).toEqual([]);
  });

  it('não tem permissão de DELETE nem de TRUNCATE em nenhuma tabela', async () => {
    for (const table of await publicTables()) {
      const { rows } = await ownerPool.query(
        `SELECT has_table_privilege('farmaerp_app', $1::oid, 'DELETE') AS can_delete,
                has_table_privilege('farmaerp_app', $1::oid, 'TRUNCATE') AS can_truncate`,
        [table.oid],
      );
      expect(rows[0], table.relname).toEqual({ can_delete: false, can_truncate: false });
    }
  });

  it('não acessa a tabela de controle das migrations', async () => {
    const { rows } = await ownerPool.query(
      `SELECT has_schema_privilege('farmaerp_app', 'db_migrations', 'USAGE') AS allowed`,
    );
    expect(rows[0].allowed).toBe(false);
  });

  it('toda view pública usa security_invoker', async () => {
    const { rows } = await ownerPool.query(`
      SELECT c.relname, c.reloptions
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind = 'v'`);
    expect(rows.map((view) => view.relname)).toEqual(
      expect.arrayContaining(EXPECTED_TABLES.map((table) => `v_${table}`)),
    );
    for (const view of rows) {
      expect(view.reloptions, view.relname).toContain('security_invoker=true');
    }
  });
});
