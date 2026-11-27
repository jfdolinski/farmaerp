import { randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { appPool, asUser, closePools, createFixtures, hasCode, ownerPool } from './helpers.mjs';

let a;

beforeAll(async () => {
  ({ a } = await createFixtures());
});
afterAll(closePools);

function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = [...base].reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const create = (client, data = {}) =>
  client.query('SELECT app.create_product($1::jsonb) AS id', [JSON.stringify({ displayName: 'Produto unidade', barcode: gtin(), ...data })])
    .then((r) => r.rows[0].id);
const unitOf = (client, id) => client.query('SELECT unit FROM v_product WHERE id = $1', [id]).then((r) => r.rows[0].unit);
const expectCode = async (client, call, code) => {
  await client.query('SAVEPOINT s');
  await expect(call()).rejects.toSatisfy(hasCode(code));
  await client.query('ROLLBACK TO s');
};

describe('unidade de medida do produto', () => {
  it('lista fixa: sigla, nome e se aceita casas decimais', async () => {
    const { rows } = await appPool.query('SELECT code, name, fractional FROM app.measure_units()');
    expect(rows.map((r) => r.code)).toEqual(['UN', 'CX', 'FR', 'AMP', 'TB', 'BIS', 'PCT', 'KIT', 'PAR', 'DZ', 'L', 'ML', 'KG', 'G', 'M', 'CM']);
    expect(rows.find((r) => r.code === 'UN')).toEqual({ code: 'UN', name: 'Unidade', fractional: false });
    expect(rows.find((r) => r.code === 'KG')).toEqual({ code: 'KG', name: 'Quilograma', fractional: true });
    expect(rows.filter((r) => r.fractional).map((r) => r.code)).toEqual(['L', 'ML', 'KG', 'G', 'M', 'CM']);
  });

  it('cadastro: sem informar fica UN; informada, aceita minúscula e com espaço', async () => {
    await asUser(a.admin.id, async (client) => {
      expect(await unitOf(client, await create(client))).toBe('UN');
      expect(await unitOf(client, await create(client, { unit: ' kg ' }))).toBe('KG');
      expect(await unitOf(client, await create(client, { unit: '' }))).toBe('UN');
    });
  });

  it('alteração: troca a unidade; sem informar, mantém a que tem', async () => {
    await asUser(a.admin.id, async (client) => {
      const id = await create(client, { unit: 'FR' });
      await client.query('SELECT app.update_product($1, $2::jsonb)', [id, JSON.stringify({ displayName: 'Produto unidade' })]);
      expect(await unitOf(client, id)).toBe('FR');
      await client.query('SELECT app.update_product($1, $2::jsonb)', [id, JSON.stringify({ displayName: 'Produto unidade', unit: 'ml' })]);
      expect(await unitOf(client, id)).toBe('ML');
    });
  });

  it('unidade fora da lista é recusada, no cadastro, na alteração e direto na tabela', async () => {
    await asUser(a.admin.id, async (client) => {
      await expectCode(client, () => create(client, { unit: 'XX' }), 'FA766');
      const id = await create(client);
      await expectCode(client, () => client.query('SELECT app.update_product($1, $2::jsonb)', [id, JSON.stringify({ displayName: 'x', unit: 'LITRO' })]), 'FA766');
      expect(await unitOf(client, id)).toBe('UN');
    });
    const owner = await ownerPool.connect();
    try {
      await owner.query('BEGIN');
      await owner.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
      const id = await create(owner);
      await owner.query('SAVEPOINT s');
      await expect(owner.query(`UPDATE product SET unit = 'XX' WHERE id = $1`, [id])).rejects.toMatchObject({ constraint: 'product_unit_check' });
      await owner.query('ROLLBACK TO s');
    } finally {
      await owner.query('ROLLBACK');
      owner.release();
    }
  });

  it('o produto desce ao PDV com a unidade', async () => {
    const owner = await ownerPool.connect();
    try {
      await owner.query('BEGIN');
      await owner.query(`SELECT set_config('app.user_id', $1, true)`, [a.admin.id]);
      const id = await create(owner, { unit: 'CX' });
      const { rows: [row] } = await owner.query('SELECT data FROM app.pdv_product_data($1, ARRAY[$2]::uuid[])', [a.branch1.id, id]);
      expect(row.data.unit).toBe('CX');
    } finally {
      await owner.query('ROLLBACK');
      owner.release();
    }
  });

  it('o cadastro duplicado na conferência da nota leva a unidade do original', async () => {
    const source = (await ownerPool.query('SELECT prosrc FROM pg_proc WHERE proname = $1', ['duplicate_product_for_item'])).rows[0].prosrc;
    expect(source).toContain("'unit', source.unit");
  });

  it('grupo novo: o Gerente não recebe o cancelar nota (permissão fica para o perfil)', async () => {
    const { rows } = await ownerPool.query(
      `SELECT p.code FROM role_permission rp JOIN permission p ON p.id = rp.permission_id
        WHERE rp.role_id = $1 AND p.code = 'purchases.cancel' AND rp.deleted_at IS NULL`,
      [a.managerRole.id],
    );
    expect(rows).toEqual([]);
  });
});
