import { randomBytes, randomInt } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  appPool, asOwner, asUser, closePools, createFixtures, hasCode, ownerPool, setUser,
} from './helpers.mjs';

let a;
let b;

function gtin() {
  let base = '';
  for (let i = 0; i < 12; i += 1) base += String(randomInt(10));
  const total = base.split('').reverse().reduce((sum, c, i) => sum + Number(c) * (i % 2 === 0 ? 3 : 1), 0);
  return `${base}${(10 - (total % 10)) % 10}`;
}
const tag = () => randomBytes(4).toString('hex');
const FUTURE = '2090-01-31';

/** Cria o produto e devolve o que os testes usam para localizar. */
const newProduct = async (client, overrides = {}) => {
  const barcode = overrides.barcode ?? gtin();
  const { rows } = await client.query('SELECT app.create_product($1::jsonb) AS id', [
    JSON.stringify({ displayName: `Produto ${tag()}`, barcode, ...overrides }),
  ]);
  return { id: rows[0].id, barcode };
};
const track = (client, product, branch, tracks = true) =>
  client.query('SELECT app.set_batch_tracking($1, $2, $3)', [product.id, branch.id, tracks]);
const adjust = (client, product, branch, quantity, extra = {}) =>
  client.query('SELECT app.adjust_stock($1::jsonb) AS id', [JSON.stringify({
    productLookup: product.barcode, branchId: branch.id, direction: quantity > 0 ? 'in' : 'out',
    quantity: Math.abs(quantity), reason: 'Teste', ...extra,
  })]).then((r) => r.rows[0].id);
const loss = (client, product, branch, quantity, extra = {}) =>
  client.query('SELECT app.register_stock_loss($1::jsonb) AS id', [JSON.stringify({
    productLookup: product.barcode, branchId: branch.id, quantity, reason: 'Quebra', ...extra,
  })]).then((r) => r.rows[0].id);
const reverse = (client, id, reason = 'Lançado errado') =>
  client.query('SELECT app.reverse_stock_movement($1, $2) AS id', [id, reason]).then((r) => r.rows[0].id);
const overview = async (client, product, branch = null) =>
  (await client.query('SELECT * FROM app.stock_overview(NULL, $1, $2, true)', [branch?.id ?? null, product.id])).rows;
const balance = async (client, product, branch) => {
  const rows = await overview(client, product, branch);
  return rows.reduce((sum, row) => sum + Number(row.quantity), 0);
};

async function committed(userId, fn) {
  const client = await appPool.connect();
  try {
    await client.query('BEGIN');
    await setUser(client, userId);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

async function userWith(client, codes, { branches = [], scope = null, group = a.group } = {}) {
  const { rows: [user] } = await client.query(
    'INSERT INTO user_account (economic_group_id, name) VALUES ($1, $2) RETURNING *',
    [group.id, `Usuário ${tag()}`],
  );
  const { rows: [role] } = await client.query(
    'INSERT INTO role (economic_group_id, name) VALUES ($1, $2) RETURNING *',
    [group.id, `Perfil ${tag()}`],
  );
  await client.query(
    'INSERT INTO role_permission (role_id, permission_id) SELECT $1, id FROM permission WHERE code = ANY ($2)',
    [role.id, codes],
  );
  for (const branch of branches) {
    await client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [user.id, branch.id]);
  }
  await client.query('INSERT INTO user_role (user_id, role_id, branch_id) VALUES ($1, $2, $3)', [user.id, role.id, scope?.id ?? null]);
  return user;
}

const freshControlled = async () => {
  const code = gtin();
  const { rows } = await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [JSON.stringify({
    sourceKey: `ctrl-${tag()}`, name: `Controlado ${tag()}`, controlledClass: 'B1',
    msRegistration: '1000000000099', barcodes: [code],
  })]);
  return { catalogProductId: rows[0].id, barcode: code };
};

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

describe('movimentação e saldo', () => {
  it('entrada e saída mudam o saldo por filial, e o total da rede soma', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await adjust(client, product, a.branch1, 10);
      await adjust(client, product, a.branch2, 4.5);
      await adjust(client, product, a.branch1, -3);
      expect(await balance(client, product, a.branch1)).toBe(7);
      expect(await balance(client, product, a.branch2)).toBe(4.5);
      const { rows } = await client.query('SELECT quantity FROM v_stock_network_total WHERE product_id = $1', [product.id]);
      expect(Number(rows[0].quantity)).toBe(11.5);
    });
  });

  it('movimentação fica registrada com autor e motivo', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await adjust(client, product, a.branch1, 10, { reason: 'Carga inicial' });
      const { rows } = await client.query('SELECT * FROM app.list_stock_movements($1)', [product.id]);
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ movement_type: 'adjustment', quantity: '10.000', reason: 'Carga inicial', author: a.admin.name });
    });
  });

  it('nem o dono altera ou apaga uma movimentação', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      const id = await adjust(client, product, a.branch1, 10);
      await client.query('SAVEPOINT s');
      await expect(client.query('UPDATE stock_movement SET quantity = 1 WHERE id = $1', [id])).rejects.toSatisfy(hasCode('FA104'));
      await client.query('ROLLBACK TO s');
      await expect(client.query('UPDATE stock_movement SET deleted_at = now() WHERE id = $1', [id])).rejects.toSatisfy(hasCode('FA104'));
    });
  });

  it('a conferência não acha diferença entre saldo e movimentações', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await adjust(client, product, a.branch1, 10);
      await adjust(client, product, a.branch1, -4);
      const { rows } = await client.query('SELECT * FROM app.stock_balance_divergences() WHERE product_id = $1', [product.id]);
      expect(rows).toEqual([]);
    });
  });

  it('a conferência aponta um saldo mexido por fora', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      await adjust(client, product, a.branch1, 10);
      await client.query('UPDATE stock_balance SET quantity = 99 WHERE product_id = $1', [product.id]);
      const { rows } = await client.query('SELECT * FROM app.stock_balance_divergences() WHERE product_id = $1', [product.id]);
      expect(rows).toHaveLength(1);
      expect(Number(rows[0].movements)).toBe(10);
    });
  });
});

describe('saldo negativo', () => {
  it.each([
    ['ajuste', (client, product) => adjust(client, product, a.branch1, -11)],
    ['perda', (client, product) => loss(client, product, a.branch1, 11)],
  ])('%s não deixa o saldo negativo', async (_label, action) => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await adjust(client, product, a.branch1, 10);
      await client.query('SAVEPOINT s');
      await expect(action(client, product)).rejects.toSatisfy(hasCode('FA801'));
      await client.query('ROLLBACK TO s');
      expect(await balance(client, product, a.branch1)).toBe(10);
    });
  });

  it('venda pode deixar negativo, e a entrada seguinte é aceita mesmo sem cobrir tudo', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      await adjust(client, product, a.branch1, 2);
      await client.query(
        `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity)
         VALUES ($1, $2, $3, 'sale', -5)`,
        [a.group.id, a.branch1.id, product.id],
      );
      expect(await balance(client, product, a.branch1)).toBe(-3);
      await adjust(client, product, a.branch1, 1);
      expect(await balance(client, product, a.branch1)).toBe(-2);
      await client.query('SAVEPOINT s');
      await expect(adjust(client, product, a.branch1, -1)).rejects.toSatisfy(hasCode('FA801'));
    });
  });

  it('duas saídas ao mesmo tempo não passam juntas', async () => {
    const product = await committed(a.admin.id, async (client) => {
      const created = await newProduct(client);
      await adjust(client, created, a.branch1, 10);
      return created;
    });
    const results = await Promise.allSettled([
      committed(a.admin.id, (client) => loss(client, product, a.branch1, 6)),
      committed(a.admin.id, (client) => loss(client, product, a.branch1, 6)),
    ]);
    const failures = results.filter((result) => result.status === 'rejected');
    expect(failures).toHaveLength(1);
    expect(hasCode('FA801')(failures[0].reason)).toBe(true);
    const { rows } = await ownerPool.query('SELECT quantity FROM stock_balance WHERE product_id = $1', [product.id]);
    expect(Number(rows[0].quantity)).toBe(4);
  });

  it('entradas simultâneas somam certo, na primeira linha do saldo', async () => {
    const product = await committed(a.admin.id, (client) => newProduct(client));
    await Promise.all(Array.from({ length: 12 }, () =>
      committed(a.admin.id, (client) => adjust(client, product, a.branch1, 1))));
    const { rows } = await ownerPool.query('SELECT quantity FROM stock_balance WHERE product_id = $1', [product.id]);
    expect(rows).toHaveLength(1);
    expect(Number(rows[0].quantity)).toBe(12);
  });
});

describe('validações da movimentação', () => {
  it.each([0, -1])('quantidade %s é recusada', async (quantity) => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await expect(adjust(client, product, a.branch1, 1, { quantity })).rejects.toSatisfy(hasCode('FA810'));
    });
  });

  it('direção desconhecida é recusada', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await expect(adjust(client, product, a.branch1, 1, { direction: 'lado' })).rejects.toSatisfy(hasCode('FA810'));
    });
  });

  it('motivo é obrigatório', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await client.query('SAVEPOINT s');
      await expect(adjust(client, product, a.branch1, 1, { reason: ' ' })).rejects.toSatisfy(hasCode('FA302'));
      await client.query('ROLLBACK TO s');
      await expect(loss(client, product, a.branch1, 1, { reason: '' })).rejects.toSatisfy(hasCode('FA302'));
    });
  });

  it('produto que não existe é recusado', async () => {
    await asUser(a.admin.id, async (client) => {
      await expect(adjust(client, { barcode: 'naoexiste' }, a.branch1, 1)).rejects.toSatisfy(hasCode('FA004'));
    });
  });

  it('tipo desconhecido é recusado, mesmo pelo dono', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      await expect(client.query(
        `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity)
         VALUES ($1, $2, $3, 'sumiu', 1)`,
        [a.group.id, a.branch1.id, product.id],
      )).rejects.toSatisfy(hasCode('FA810'));
    });
  });

  it('não cruza grupos: filial de outro grupo é recusada, mesmo pelo dono', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      await expect(client.query(
        `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity)
         VALUES ($1, $2, $3, 'adjustment', 1)`,
        [a.group.id, b.branch1.id, product.id],
      )).rejects.toSatisfy(hasCode('FA004'));
    });
  });
});

describe('estorno', () => {
  it('desfaz o saldo com movimentação contrária, ligada à original', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      const id = await adjust(client, product, a.branch1, 10);
      await reverse(client, id);
      expect(await balance(client, product, a.branch1)).toBe(0);
      const { rows } = await client.query('SELECT id, quantity, reversal_of, reversed FROM app.list_stock_movements($1) ORDER BY id', [product.id]);
      expect(rows).toHaveLength(2);
      expect(rows[0]).toMatchObject({ id, reversed: true });
      expect(rows[1]).toMatchObject({ reversal_of: id, quantity: '-10.000' });
    });
  });

  it('não estorna duas vezes', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      const id = await adjust(client, product, a.branch1, 10);
      await reverse(client, id);
      await expect(reverse(client, id)).rejects.toSatisfy(hasCode('FA812'));
    });
  });

  it('não estorna um estorno', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      const reversal = await reverse(client, await adjust(client, product, a.branch1, 10));
      await expect(reverse(client, reversal)).rejects.toSatisfy(hasCode('FA811'));
    });
  });

  it('entrada que já saiu não pode ser estornada', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      const id = await adjust(client, product, a.branch1, 10);
      await adjust(client, product, a.branch1, -8);
      await expect(reverse(client, id)).rejects.toSatisfy(hasCode('FA801'));
    });
  });

  it('venda não é estornada por aqui', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      const { rows: [sale] } = await client.query(
        `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity)
         VALUES ($1, $2, $3, 'sale', -1) RETURNING id`,
        [a.group.id, a.branch1.id, product.id],
      );
      await expect(reverse(client, sale.id)).rejects.toSatisfy(hasCode('FA811'));
    });
  });

  it('exige motivo', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      const id = await adjust(client, product, a.branch1, 10);
      await expect(reverse(client, id, ' ')).rejects.toSatisfy(hasCode('FA302'));
    });
  });

  it('estorno inconsistente é recusado, mesmo pelo dono', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      const id = await adjust(client, product, a.branch1, 10);
      await expect(client.query(
        `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, movement_type, quantity, reversal_of)
         VALUES ($1, $2, $3, 'adjustment', -3, $4)`,
        [a.group.id, a.branch1.id, product.id, id],
      )).rejects.toSatisfy(hasCode('FA811'));
    });
  });
});

describe('controle de lote', () => {
  it('sem controle, o saldo não tem lote, e lote é recusado', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await adjust(client, product, a.branch1, 5);
      await expect(adjust(client, product, a.branch1, 5, { batchNumber: 'L1', expiresOn: FUTURE })).rejects.toSatisfy(hasCode('FA803'));
    });
  });

  it('o parâmetro vale por filial: uma loja controla e a outra não', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await track(client, product, a.branch1);
      await client.query('SAVEPOINT s');
      await expect(adjust(client, product, a.branch1, 5)).rejects.toSatisfy(hasCode('FA802'));
      await client.query('ROLLBACK TO s');
      await adjust(client, product, a.branch1, 5, { batchNumber: 'L1', expiresOn: FUTURE });
      await adjust(client, product, a.branch2, 5);
      const rows = await overview(client, product);
      expect(rows.find((row) => row.branch_id === a.branch1.id).batch_number).toBe('L1');
      expect(rows.find((row) => row.branch_id === a.branch2.id).batch_id).toBeNull();
    });
  });

  it('controlado exige lote mesmo sem o parâmetro, e não desliga', async () => {
    const controlled = await freshControlled();
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client, controlled);
      await client.query('SAVEPOINT s');
      await expect(adjust(client, product, a.branch1, 5)).rejects.toSatisfy(hasCode('FA802'));
      await client.query('ROLLBACK TO s');
      await expect(track(client, product, a.branch1, false)).rejects.toSatisfy(hasCode('FA807'));
    });
  });

  it('a grade da tela informa que é controlado', async () => {
    const controlled = await freshControlled();
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client, controlled);
      const { rows } = await client.query('SELECT * FROM app.batch_tracking_grid($1)', [product.id]);
      expect(rows.every((row) => row.is_controlled)).toBe(true);
    });
  });

  it('ligar com saldo sem lote é recusado; zerado, liga', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await adjust(client, product, a.branch1, 5);
      await client.query('SAVEPOINT s');
      await expect(track(client, product, a.branch1)).rejects.toSatisfy(hasCode('FA809'));
      await client.query('ROLLBACK TO s');
      await adjust(client, product, a.branch1, -5);
      await track(client, product, a.branch1);
    });
  });

  it('desligar com saldo em lote é recusado; zerado, desliga', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await track(client, product, a.branch1);
      await adjust(client, product, a.branch1, 5, { batchNumber: 'L1', expiresOn: FUTURE });
      await client.query('SAVEPOINT s');
      await expect(track(client, product, a.branch1, false)).rejects.toSatisfy(hasCode('FA809'));
      await client.query('ROLLBACK TO s');
      await adjust(client, product, a.branch1, -5, { batchNumber: 'L1' });
      await track(client, product, a.branch1, false);
    });
  });

  it('saldo em outra filial não impede', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await adjust(client, product, a.branch2, 5);
      await track(client, product, a.branch1);
    });
  });

  it('produto que vira controlado: saldo antigo avisa, só pode sair, e entrada exige lote', async () => {
    const code = gtin();
    const sourceKey = `vira-${tag()}`;
    const item = (extra) => JSON.stringify({ sourceKey, name: 'Vira controlado', barcodes: [code], ...extra });
    const { rows: [{ id: catalogProductId }] } = await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb) AS id', [item({})]);
    const product = await committed(a.admin.id, async (client) => {
      const created = await newProduct(client, { catalogProductId, barcode: code });
      await adjust(client, created, a.branch1, 5);
      return created;
    });
    await ownerPool.query('SELECT app.upsert_catalog_product($1::jsonb)', [item({ controlledClass: 'C1' })]);

    await asUser(a.admin.id, async (client) => {
      const [row] = await overview(client, product, a.branch1);
      expect(row.needs_batch).toBe(true);
      await client.query('SAVEPOINT s');
      await expect(adjust(client, product, a.branch1, 1)).rejects.toSatisfy(hasCode('FA802'));
      await client.query('ROLLBACK TO s');
      await adjust(client, product, a.branch1, -5);
      expect(await balance(client, product, a.branch1)).toBe(0);
      await expect(adjust(client, product, a.branch1, -1)).rejects.toSatisfy(hasCode('FA802'));
    });
  });
});

describe('lote', () => {
  const tracked = async (client, overrides = {}) => {
    const product = await newProduct(client, overrides);
    await track(client, product, a.branch1);
    await track(client, product, a.branch2);
    return product;
  };

  it('saldo separa por lote, e o número é igual com ou sem caixa alta', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await tracked(client);
      await adjust(client, product, a.branch1, 5, { batchNumber: 'abc1', expiresOn: FUTURE });
      await adjust(client, product, a.branch1, 3, { batchNumber: ' ABC1 ' });
      await adjust(client, product, a.branch1, 2, { batchNumber: 'XYZ', expiresOn: FUTURE });
      const rows = await overview(client, product, a.branch1);
      expect(rows.map((row) => [row.batch_number, Number(row.quantity)]).sort()).toEqual([['ABC1', 8], ['XYZ', 2]]);
    });
  });

  it('o mesmo número em outra filial é outro cadastro, com validade própria', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await tracked(client);
      await adjust(client, product, a.branch1, 5, { batchNumber: 'L1', expiresOn: '2090-01-01' });
      await adjust(client, product, a.branch2, 5, { batchNumber: 'L1', expiresOn: '2091-01-01' });
      const { rows } = await client.query('SELECT branch_id, expires_on FROM v_product_batch WHERE product_id = $1', [product.id]);
      expect(rows).toHaveLength(2);
      expect(new Set(rows.map((row) => row.expires_on.toISOString())).size).toBe(2);
    });
  });

  it('lote novo sem validade é recusado', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await tracked(client);
      await expect(adjust(client, product, a.branch1, 5, { batchNumber: 'L1' })).rejects.toSatisfy(hasCode('FA806'));
    });
  });

  it('lote existente com outra validade ou outro MS é recusado', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await tracked(client);
      await adjust(client, product, a.branch1, 5, { batchNumber: 'L1', expiresOn: FUTURE, msRegistration: '1111111111111' });
      await client.query('SAVEPOINT s');
      await expect(adjust(client, product, a.branch1, 5, { batchNumber: 'L1', expiresOn: '2091-01-01' })).rejects.toSatisfy(hasCode('FA804'));
      await client.query('ROLLBACK TO s');
      await expect(adjust(client, product, a.branch1, 5, { batchNumber: 'L1', msRegistration: '2222222222222' })).rejects.toSatisfy(hasCode('FA804'));
    });
  });

  it('saída de lote que não existe é recusada', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await tracked(client);
      await client.query('SAVEPOINT s');
      await expect(adjust(client, product, a.branch1, -1, { batchNumber: 'NAO' })).rejects.toSatisfy(hasCode('FA808'));
      await client.query('ROLLBACK TO s');
      await expect(loss(client, product, a.branch1, 1, { batchNumber: 'NAO' })).rejects.toSatisfy(hasCode('FA808'));
    });
  });

  it('saldo é por lote: um lote não cobre a saída de outro', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await tracked(client);
      await adjust(client, product, a.branch1, 5, { batchNumber: 'A', expiresOn: FUTURE });
      await adjust(client, product, a.branch1, 1, { batchNumber: 'B', expiresOn: FUTURE });
      await expect(loss(client, product, a.branch1, 2, { batchNumber: 'B' })).rejects.toSatisfy(hasCode('FA801'));
    });
  });

  it('movimentação não usa lote de outra filial ou produto, mesmo pelo dono', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await tracked(client);
      await adjust(client, product, a.branch1, 5, { batchNumber: 'A', expiresOn: FUTURE });
      const { rows: [batch] } = await client.query('SELECT id FROM product_batch WHERE product_id = $1', [product.id]);
      await expect(client.query(
        `INSERT INTO stock_movement (economic_group_id, branch_id, product_id, batch_id, movement_type, quantity)
         VALUES ($1, $2, $3, $4, 'adjustment', 1)`,
        [a.group.id, a.branch2.id, product.id, batch.id],
      )).rejects.toSatisfy(hasCode('FA808'));
    });
  });

  it('estorno devolve ao mesmo lote', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await tracked(client);
      await adjust(client, product, a.branch1, 5, { batchNumber: 'A', expiresOn: FUTURE });
      const id = await loss(client, product, a.branch1, 2, { batchNumber: 'A' });
      await reverse(client, id);
      const [row] = await overview(client, product, a.branch1);
      expect(Number(row.quantity)).toBe(5);
    });
  });

  it('avisa lote vencido e dias até vencer', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await tracked(client);
      await adjust(client, product, a.branch1, 1, { batchNumber: 'VELHO', expiresOn: '2020-01-01' });
      await adjust(client, product, a.branch1, 1, { batchNumber: 'NOVO', expiresOn: FUTURE });
      const rows = await overview(client, product, a.branch1);
      expect(rows[0]).toMatchObject({ batch_number: 'VELHO', is_expired: true });
      expect(rows[0].days_to_expire).toBeLessThan(0);
      expect(rows[1]).toMatchObject({ batch_number: 'NOVO', is_expired: false });
    });
  });

  it('MS: herda o do Catálogo, avisa divergência e guarda o original', async () => {
    const controlled = await freshControlled();
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client, controlled);
      await adjust(client, product, a.branch1, 1, { batchNumber: 'HERDA', expiresOn: FUTURE });
      await adjust(client, product, a.branch1, 1, { batchNumber: 'OUTRO', expiresOn: FUTURE, msRegistration: '2222222222222' });
      const rows = await overview(client, product, a.branch1);
      const byNumber = Object.fromEntries(rows.map((row) => [row.batch_number, row]));
      expect(byNumber.HERDA).toMatchObject({ ms_registration: '1000000000099', ms_diverges: false, ms_original: '1000000000099' });
      expect(byNumber.OUTRO).toMatchObject({ ms_registration: '2222222222222', ms_diverges: true, ms_original: '2222222222222' });
    });
  });

  it('editar lote guarda o valor anterior, o motivo e não perde o MS original', async () => {
    const controlled = await freshControlled();
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client, controlled);
      await adjust(client, product, a.branch1, 1, { batchNumber: 'A', expiresOn: FUTURE });
      const { rows: [{ id }] } = await client.query('SELECT id FROM v_product_batch WHERE product_id = $1', [product.id]);
      await client.query('SELECT app.update_product_batch($1, $2::jsonb)', [id, JSON.stringify({
        batchNumber: 'b', expiresOn: '2091-02-01', msRegistration: '3333333333333', reason: 'Nota corrigida',
      })]);
      const { rows: [batch] } = await client.query('SELECT batch_number, ms_registration, ms_original FROM v_product_batch WHERE id = $1', [id]);
      expect(batch).toEqual({ batch_number: 'B', ms_registration: '3333333333333', ms_original: '1000000000099' });
      const { rows: [event] } = await client.query('SELECT * FROM v_product_batch_event WHERE batch_id = $1', [id]);
      expect(event).toMatchObject({ old_number: 'A', new_number: 'B', old_ms: '1000000000099', new_ms: '3333333333333', reason: 'Nota corrigida', updated_by: a.admin.id });
    });
  });

  it('edição exige motivo, e não repete número nem aceita MS inválido', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await tracked(client);
      await adjust(client, product, a.branch1, 1, { batchNumber: 'A', expiresOn: FUTURE });
      await adjust(client, product, a.branch1, 1, { batchNumber: 'B', expiresOn: FUTURE });
      const { rows } = await client.query('SELECT id, batch_number FROM v_product_batch WHERE product_id = $1', [product.id]);
      const id = rows.find((row) => row.batch_number === 'A').id;
      const edit = (data) => client.query('SELECT app.update_product_batch($1, $2::jsonb)', [id, JSON.stringify(data)]);
      await client.query('SAVEPOINT s');
      await expect(edit({ batchNumber: 'A', reason: '' })).rejects.toSatisfy(hasCode('FA302'));
      await client.query('ROLLBACK TO s');
      await expect(edit({ batchNumber: 'B', reason: 'x' })).rejects.toSatisfy(hasCode('FA805'));
      await client.query('ROLLBACK TO s');
      await expect(edit({ msRegistration: 'abc', reason: 'x' })).rejects.toSatisfy(hasCode('FA806'));
    });
  });
});

describe('permissões', () => {
  it('a API não escreve direto nas tabelas', async () => {
    const { rows } = await ownerPool.query(`
      SELECT t.name, has_table_privilege('farmaerp_app', t.name, 'INSERT') AS ins,
             has_table_privilege('farmaerp_app', t.name, 'UPDATE') AS upd
        FROM unnest(ARRAY['product_batch', 'product_batch_event', 'stock_movement', 'stock_balance']) AS t(name)`);
    expect(rows.every((row) => !row.ins && !row.upd)).toBe(true);
  });

  it('Gerente pode perda, mas não ajuste, nem lote, nem estorno', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      const id = await adjust(client, product, a.branch1, 10);
      const manager = await userWith(client, [], { branches: [a.branch1] });
      await client.query('INSERT INTO user_role (user_id, role_id) VALUES ($1, $2)', [manager.id, a.managerRole.id]);
      await setUser(client, manager.id);
      await loss(client, product, a.branch1, 1);
      for (const call of [
        () => adjust(client, product, a.branch1, 1),
        () => track(client, product, a.branch1),
        () => reverse(client, id),
      ]) {
        await client.query('SAVEPOINT s');
        await expect(call()).rejects.toSatisfy(hasCode('FA002'));
        await client.query('ROLLBACK TO s');
      }
    });
  });

  it('perfil de uma filial não mexe em outra', async () => {
    await asOwner(async (client) => {
      await setUser(client, a.admin.id);
      const product = await newProduct(client);
      await adjust(client, product, a.branch2, 10);
      const local = await userWith(client, ['stock.adjust', 'stock.loss'], { branches: [a.branch1], scope: a.branch1 });
      await setUser(client, local.id);
      await adjust(client, product, a.branch1, 1);
      await client.query('SAVEPOINT s');
      await expect(adjust(client, product, a.branch2, 1)).rejects.toSatisfy(hasCode('FA002'));
      await client.query('ROLLBACK TO s');
      await expect(loss(client, product, a.branch2, 1)).rejects.toSatisfy(hasCode('FA002'));
    });
  });

  it('quem não tem stock.view não vê saldo', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      await adjust(client, product, a.branch1, 10);
      await setUser(client, a.noBranchUser.id);
      expect(await overview(client, product)).toEqual([]);
      expect((await client.query('SELECT 1 FROM v_stock_movement LIMIT 1')).rows).toEqual([]);
    });
  });

  it('quem vê só uma filial não vê o saldo da outra, nem no total', async () => {
    const product = await committed(a.admin.id, async (client) => {
      const created = await newProduct(client);
      await adjust(client, created, a.branch1, 10);
      await adjust(client, created, a.branch2, 7);
      return created;
    });
    const owner = await ownerPool.connect();
    let local;
    try {
      await owner.query('BEGIN');
      local = await userWith(owner, ['stock.view', 'products.view'], { branches: [a.branch1], scope: a.branch1 });
      await owner.query('COMMIT');
    } finally {
      owner.release();
    }
    await asUser(local.id, async (client) => {
      const rows = await overview(client, product);
      expect(rows.map((row) => row.branch_id)).toEqual([a.branch1.id]);
      const { rows: total } = await client.query('SELECT quantity FROM v_stock_network_total WHERE product_id = $1', [product.id]);
      expect(Number(total[0].quantity)).toBe(10);
    });
  });

  it('outro grupo não vê nem altera', async () => {
    await asUser(a.admin.id, async (client) => {
      const product = await newProduct(client);
      const id = await adjust(client, product, a.branch1, 10);
      await setUser(client, b.admin.id);
      expect(await overview(client, product)).toEqual([]);
      await client.query('SAVEPOINT s');
      await expect(reverse(client, id)).rejects.toSatisfy(hasCode('FA006'));
      await client.query('ROLLBACK TO s');
      await expect(adjust(client, product, b.branch1, 1)).rejects.toSatisfy(hasCode('FA004'));
    });
  });

  it('Gerente nasce com as permissões da loja', async () => {
    const { rows } = await ownerPool.query(
      `SELECT p.code FROM role_permission rp JOIN permission p ON p.id = rp.permission_id
        WHERE rp.role_id = $1 AND p.code LIKE 'stock.%' ORDER BY p.code`,
      [a.managerRole.id],
    );
    expect(rows.map((row) => row.code)).toEqual(['stock.batch_override', 'stock.loss', 'stock.transfer', 'stock.view']);
  });
});
