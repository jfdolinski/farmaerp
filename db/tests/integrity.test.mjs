import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  asOwner, branchCnpj, closePools, createFixtures, hasCode, ownerPool, randomRoot, withCheckDigits,
} from './helpers.mjs';

let a;
let b;

beforeAll(async () => {
  ({ a, b } = await createFixtures());
});
afterAll(closePools);

const softDelete = (client, table, id) =>
  client.query(`UPDATE ${table} SET deleted_at = now() WHERE id = $1`, [id]);

describe('validação de CNPJ', () => {
  it.each([
    ['exemplo alfanumérico oficial da Receita', '12ABC34501DE35'],
    ['numérico', '11222333000181'],
    ['numérico de filial', '11222333000262'],
    ['dígito calculado à parte', withCheckDigits('ZZ9AB0C10001')],
  ])('aceita: %s', async (_label, cnpj) => {
    const { rows } = await ownerPool.query('SELECT app.is_valid_cnpj($1) AS valid', [cnpj]);
    expect(rows[0].valid).toBe(true);
  });

  it.each([
    ['dígito errado', '11222333000182'],
    ['dígito alfanumérico errado', '12ABC34501DE36'],
    ['letras minúsculas', '12abc34501de35'],
    ['letra nos dígitos verificadores', '12ABC34501DE3A'],
    ['curto', '1122233300018'],
    ['longo', '112223330001811'],
    ['com máscara', '11.222.333/0001-81'],
    ['todos zeros', '00000000000000'],
    ['todos iguais', '11111111111111'],
    ['nulo', null],
  ])('rejeita: %s', async (_label, cnpj) => {
    const { rows } = await ownerPool.query('SELECT app.is_valid_cnpj($1) AS valid', [cnpj]);
    expect(rows[0].valid).toBe(false);
  });

  it('confere com o cálculo independente em raízes aleatórias', async () => {
    for (let i = 0; i < 50; i += 1) {
      const cnpj = branchCnpj(randomRoot(), i + 1);
      const { rows } = await ownerPool.query('SELECT app.is_valid_cnpj($1) AS valid', [cnpj]);
      expect(rows[0].valid, cnpj).toBe(true);
    }
  });
});

describe('filial', () => {
  const insertBranch = (client, companyId, regionId, cnpj, name = 'Filial nova') =>
    client.query(
      'INSERT INTO branch (company_id, region_id, name, cnpj) VALUES ($1, $2, $3, $4) RETURNING id',
      [companyId, regionId, name, cnpj],
    );

  it('aceita a matriz e as demais filiais como registros iguais', async () => {
    await asOwner(async (client) => {
      const { rowCount } = await insertBranch(client, a.company.id, a.region.id, branchCnpj(a.root, 50));
      expect(rowCount).toBe(1);
    });
  });

  it('rejeita CNPJ inválido', async () => {
    await asOwner(async (client) => {
      await expect(
        insertBranch(client, a.company.id, null, `${a.root}000100`),
      ).rejects.toSatisfy(hasCode('FA211'));
    });
  });

  it('rejeita CNPJ com raiz diferente da empresa', async () => {
    await asOwner(async (client) => {
      await expect(
        insertBranch(client, a.company.id, null, branchCnpj(b.root, 60)),
      ).rejects.toSatisfy(hasCode('FA203'));
    });
  });

  it('rejeita CNPJ repetido entre filiais ativas', async () => {
    await asOwner(async (client) => {
      await expect(
        insertBranch(client, a.company.id, null, a.branch1.cnpj),
      ).rejects.toSatisfy(hasCode('FA212'));
    });
  });

  it('rejeita região de outro grupo econômico', async () => {
    await asOwner(async (client) => {
      await expect(
        insertBranch(client, a.company.id, b.region.id, branchCnpj(a.root, 61)),
      ).rejects.toSatisfy(hasCode('FA206'));
    });
  });

  it('permite ficar sem região', async () => {
    await asOwner(async (client) => {
      const { rowCount } = await insertBranch(client, a.company.id, null, branchCnpj(a.root, 62));
      expect(rowCount).toBe(1);
    });
  });

  it('rejeita empresa excluída', async () => {
    await asOwner(async (client) => {
      const root = randomRoot();
      const { rows: [company] } = await client.query(
        `INSERT INTO company (economic_group_id, legal_name, trade_name, cnpj_root, deleted_at)
         VALUES ($1, 'Excluída Ltda', 'Excluída', $2, now()) RETURNING id`,
        [a.group.id, root],
      );
      await expect(
        insertBranch(client, company.id, null, branchCnpj(root, 1)),
      ).rejects.toSatisfy(hasCode('FA204'));
    });
  });

  it('rejeita região excluída', async () => {
    await asOwner(async (client) => {
      const { rows: [region] } = await client.query(
        `INSERT INTO region (branch_group_id, name, deleted_at) VALUES ($1, 'Excluída', now()) RETURNING id`,
        [a.branchGroup.id],
      );
      await expect(
        insertBranch(client, a.company.id, region.id, branchCnpj(a.root, 63)),
      ).rejects.toSatisfy(hasCode('FA205'));
    });
  });
});

describe('região', () => {
  it('pode mudar de grupo de filial dentro do mesmo grupo econômico', async () => {
    await asOwner(async (client) => {
      const { rows: [target] } = await client.query(
        `INSERT INTO branch_group (economic_group_id, name) VALUES ($1, 'Destino') RETURNING id`,
        [a.group.id],
      );
      const { rowCount } = await client.query(
        'UPDATE region SET branch_group_id = $1 WHERE id = $2',
        [target.id, a.region.id],
      );
      expect(rowCount).toBe(1);
    });
  });

  it('não pode mudar para outro grupo econômico', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query('UPDATE region SET branch_group_id = $1 WHERE id = $2', [b.branchGroup.id, a.region.id]),
      ).rejects.toSatisfy(hasCode('FA207'));
    });
  });
});

describe('vínculo de usuário e filial', () => {
  it('rejeita filial de outro grupo econômico', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [a.noBranchUser.id, b.branch1.id]),
      ).rejects.toSatisfy(hasCode('FA210'));
    });
  });

  it('rejeita vínculo ativo repetido', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query('INSERT INTO user_branch (user_id, branch_id) VALUES ($1, $2)', [a.oneBranchUser.id, a.branch1.id]),
      ).rejects.toSatisfy(hasCode('FA222'));
    });
  });
});

describe('colunas imutáveis', () => {
  it.each([
    ['company', 'economic_group_id', () => [a.company.id, b.group.id]],
    ['company', 'cnpj_root', () => [a.company.id, '99999999']],
    ['branch_group', 'economic_group_id', () => [a.branchGroup.id, b.group.id]],
    ['branch', 'company_id', () => [a.branch1.id, b.company.id]],
    ['user_account', 'economic_group_id', () => [a.oneBranchUser.id, b.group.id]],
    ['user_branch', 'branch_id', () => [a.oneBranchLink.id, a.branch2.id]],
    ['user_branch', 'user_id', () => [a.oneBranchLink.id, a.noBranchUser.id]],
  ])('%s.%s não pode ser alterada', async (table, column, values) => {
    await asOwner(async (client) => {
      const [id, value] = values();
      await expect(
        client.query(`UPDATE ${table} SET ${column} = $2 WHERE id = $1`, [id, value]),
      ).rejects.toSatisfy(hasCode('FA104'));
    });
  });
});

describe('exclusão lógica com filhos ativos', () => {
  it.each([
    ['economic_group', () => a.group.id],
    ['company', () => a.company.id],
    ['branch_group', () => a.branchGroup.id],
    ['region', () => a.region.id],
    ['branch', () => a.branch1.id],
    ['user_account', () => a.oneBranchUser.id],
  ])('%s é bloqueado', async (table, id) => {
    await asOwner(async (client) => {
      await expect(softDelete(client, table, id())).rejects.toSatisfy(hasCode('FA105'));
    });
  });

  it('é permitida depois que os filhos são excluídos', async () => {
    await asOwner(async (client) => {
      await softDelete(client, 'user_branch', a.oneBranchLink.id);
      const { rowCount } = await softDelete(client, 'user_account', a.oneBranchUser.id);
      expect(rowCount).toBe(1);
    });
  });

  it('não bloqueia alterações comuns no registro pai', async () => {
    await asOwner(async (client) => {
      const { rowCount } = await client.query(
        `UPDATE region SET name = 'Novo nome' WHERE id = $1`,
        [a.region.id],
      );
      expect(rowCount).toBe(1);
    });
  });
});

describe('concorrência', () => {
  it('a exclusão do pai espera a transação que está criando um filho', async () => {
    const writer = await ownerPool.connect();
    const deleter = await ownerPool.connect();
    try {
      await writer.query('BEGIN');
      await writer.query(
        `INSERT INTO terminal (branch_id, public_key) VALUES ($1, 'chave-concorrencia')`,
        [a.branchFree.id],
      );

      await deleter.query('BEGIN');
      await deleter.query(`SET LOCAL lock_timeout = '300ms'`);
      await expect(softDelete(deleter, 'branch', a.branchFree.id)).rejects.toSatisfy(hasCode('FA008'));
    } finally {
      await writer.query('ROLLBACK');
      await deleter.query('ROLLBACK');
      writer.release();
      deleter.release();
    }
  });
});

describe('terminal', () => {
  it('fica pendente sem nome e sem perfil', async () => {
    await asOwner(async (client) => {
      const { rows } = await client.query(
        `INSERT INTO terminal (branch_id, public_key) VALUES ($1, 'chave-pendente') RETURNING status`,
        [a.branch1.id],
      );
      expect(rows[0].status).toBe('pending');
    });
  });

  it('não pode ser aprovado sem nome e perfil', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query(
          `INSERT INTO terminal (branch_id, public_key, status) VALUES ($1, 'chave-sem-nome', 'active')`,
          [a.branch1.id],
        ),
      ).rejects.toSatisfy(hasCode('FA217'));
    });
  });

  it('rejeita perfil desconhecido', async () => {
    await asOwner(async (client) => {
      await expect(
        client.query(
          `INSERT INTO terminal (branch_id, public_key, profile) VALUES ($1, 'chave-perfil', 'gerente')`,
          [a.branch1.id],
        ),
      ).rejects.toSatisfy(hasCode('FA218'));
    });
  });

  it('rejeita filial excluída', async () => {
    await asOwner(async (client) => {
      await softDelete(client, 'branch', a.branchFree.id);
      await expect(
        client.query(`INSERT INTO terminal (branch_id, public_key) VALUES ($1, 'chave-filial')`, [a.branchFree.id]),
      ).rejects.toSatisfy(hasCode('FA208'));
    });
  });
});
