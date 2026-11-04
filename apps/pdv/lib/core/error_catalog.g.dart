// GERADO por packages/error-catalog/scripts/generate-dart.mjs. Não edite à mão.
// ignore_for_file: lines_longer_than_80_chars

class ErrorCatalogEntry {
  const ErrorCatalogEntry({
    required this.code,
    required this.message,
    required this.action,
    required this.retryable,
  });

  final String code;
  final String message;
  final String action;
  final bool retryable;
}

const Map<String, ErrorCatalogEntry> errorCatalog = {
  'FA000': ErrorCatalogEntry(
    code: 'FA000',
    message: 'Não foi possível concluir a operação.',
    action: 'Tente novamente. Se continuar, informe o código e a referência ao suporte.',
    retryable: true,
  ),
  'FA001': ErrorCatalogEntry(
    code: 'FA001',
    message: 'Sistema indisponível no momento.',
    action: 'Aguarde alguns instantes e tente novamente.',
    retryable: true,
  ),
  'FA002': ErrorCatalogEntry(
    code: 'FA002',
    message: 'Você não tem permissão para esta operação.',
    action: 'Peça a liberação a um administrador.',
    retryable: false,
  ),
  'FA003': ErrorCatalogEntry(
    code: 'FA003',
    message: 'Já existe um cadastro com estes dados.',
    action: 'Confira os dados informados.',
    retryable: false,
  ),
  'FA004': ErrorCatalogEntry(
    code: 'FA004',
    message: 'Um dos itens informados não foi encontrado.',
    action: 'Atualize a tela e selecione o item novamente.',
    retryable: false,
  ),
  'FA005': ErrorCatalogEntry(
    code: 'FA005',
    message: 'Alguns dados informados são inválidos.',
    action: 'Confira os dados e tente novamente.',
    retryable: false,
  ),
  'FA006': ErrorCatalogEntry(
    code: 'FA006',
    message: 'O recurso solicitado não foi encontrado.',
    action: 'Atualize a tela e tente novamente.',
    retryable: false,
  ),
  'FA007': ErrorCatalogEntry(
    code: 'FA007',
    message: 'Não foi possível entender a solicitação.',
    action: 'Atualize o sistema e tente novamente.',
    retryable: false,
  ),
  'FA008': ErrorCatalogEntry(
    code: 'FA008',
    message: 'Outra operação está usando estes dados.',
    action: 'Aguarde alguns instantes e tente novamente.',
    retryable: true,
  ),
  'FA009': ErrorCatalogEntry(
    code: 'FA009',
    message: 'Muitas tentativas em pouco tempo.',
    action: 'Aguarde um minuto e tente novamente.',
    retryable: true,
  ),
  'FA101': ErrorCatalogEntry(
    code: 'FA101',
    message: 'Este registro não pode ter o identificador alterado.',
    action: 'Cancele a alteração e informe o suporte.',
    retryable: false,
  ),
  'FA102': ErrorCatalogEntry(
    code: 'FA102',
    message: 'A data de criação do registro não pode ser alterada.',
    action: 'Cancele a alteração e informe o suporte.',
    retryable: false,
  ),
  'FA103': ErrorCatalogEntry(
    code: 'FA103',
    message: 'Registros não podem ser apagados. Use a exclusão lógica.',
    action: 'Use a opção de excluir da tela de cadastro.',
    retryable: false,
  ),
  'FA104': ErrorCatalogEntry(
    code: 'FA104',
    message: 'Este dado não pode ser alterado depois do cadastro.',
    action: 'Se o dado estiver errado, crie um novo cadastro.',
    retryable: false,
  ),
  'FA105': ErrorCatalogEntry(
    code: 'FA105',
    message: 'Este registro ainda tem itens ativos vinculados.',
    action: 'Exclua ou mova esses itens primeiro.',
    retryable: false,
  ),
  'FA106': ErrorCatalogEntry(
    code: 'FA106',
    message: 'O identificador do registro é inválido.',
    action: 'Atualize o sistema e tente novamente.',
    retryable: false,
  ),
  'FA107': ErrorCatalogEntry(
    code: 'FA107',
    message: 'Este histórico não pode ser alterado.',
    action: 'Cancele a alteração e informe o suporte.',
    retryable: false,
  ),
  'FA108': ErrorCatalogEntry(
    code: 'FA108',
    message: 'Não foi possível gerar o código do cadastro.',
    action: 'Tente novamente. Se continuar, informe o suporte.',
    retryable: true,
  ),
  'FA201': ErrorCatalogEntry(
    code: 'FA201',
    message: 'O grupo econômico informado não está ativo.',
    action: 'Selecione um grupo econômico ativo.',
    retryable: false,
  ),
  'FA202': ErrorCatalogEntry(
    code: 'FA202',
    message: 'O grupo de filial informado não está ativo.',
    action: 'Selecione um grupo de filial ativo.',
    retryable: false,
  ),
  'FA203': ErrorCatalogEntry(
    code: 'FA203',
    message: 'O CNPJ da filial precisa ter a mesma raiz do CNPJ da empresa.',
    action: 'Confira o CNPJ digitado ou a empresa selecionada.',
    retryable: false,
  ),
  'FA204': ErrorCatalogEntry(
    code: 'FA204',
    message: 'A empresa informada não está ativa.',
    action: 'Selecione uma empresa ativa.',
    retryable: false,
  ),
  'FA205': ErrorCatalogEntry(
    code: 'FA205',
    message: 'A região informada não está ativa.',
    action: 'Selecione uma região ativa.',
    retryable: false,
  ),
  'FA206': ErrorCatalogEntry(
    code: 'FA206',
    message: 'A região precisa ser do mesmo grupo econômico da empresa.',
    action: 'Selecione uma região do grupo econômico da empresa.',
    retryable: false,
  ),
  'FA207': ErrorCatalogEntry(
    code: 'FA207',
    message: 'A região só pode ser movida para um grupo de filial do mesmo grupo econômico.',
    action: 'Selecione um grupo de filial do mesmo grupo econômico.',
    retryable: false,
  ),
  'FA208': ErrorCatalogEntry(
    code: 'FA208',
    message: 'A filial informada não está ativa.',
    action: 'Selecione uma filial ativa.',
    retryable: false,
  ),
  'FA209': ErrorCatalogEntry(
    code: 'FA209',
    message: 'O usuário informado não está ativo.',
    action: 'Selecione um usuário ativo.',
    retryable: false,
  ),
  'FA210': ErrorCatalogEntry(
    code: 'FA210',
    message: 'O usuário só pode ser vinculado a filiais do seu grupo econômico.',
    action: 'Selecione uma filial do grupo econômico do usuário.',
    retryable: false,
  ),
  'FA211': ErrorCatalogEntry(
    code: 'FA211',
    message: 'O CNPJ informado é inválido.',
    action: 'Confira os 14 caracteres do CNPJ, sem pontuação.',
    retryable: false,
  ),
  'FA212': ErrorCatalogEntry(
    code: 'FA212',
    message: 'Já existe uma filial ativa com este CNPJ.',
    action: 'Confira o CNPJ digitado.',
    retryable: false,
  ),
  'FA213': ErrorCatalogEntry(
    code: 'FA213',
    message: 'Já existe uma empresa ativa com esta raiz de CNPJ.',
    action: 'Confira a raiz do CNPJ digitada.',
    retryable: false,
  ),
  'FA214': ErrorCatalogEntry(
    code: 'FA214',
    message: 'A raiz do CNPJ da empresa é inválida.',
    action: 'Informe os 8 primeiros caracteres do CNPJ, sem pontuação.',
    retryable: false,
  ),
  'FA215': ErrorCatalogEntry(
    code: 'FA215',
    message: 'Já existe um cadastro ativo com este nome.',
    action: 'Informe outro nome.',
    retryable: false,
  ),
  'FA216': ErrorCatalogEntry(
    code: 'FA216',
    message: 'O nome é obrigatório.',
    action: 'Preencha o nome e tente novamente.',
    retryable: false,
  ),
  'FA217': ErrorCatalogEntry(
    code: 'FA217',
    message: 'O terminal precisa de nome e perfil para ser aprovado.',
    action: 'Preencha o nome e o perfil do terminal.',
    retryable: false,
  ),
  'FA218': ErrorCatalogEntry(
    code: 'FA218',
    message: 'O perfil do terminal é inválido.',
    action: 'Selecione orçamento, caixa ou autoatendimento.',
    retryable: false,
  ),
  'FA219': ErrorCatalogEntry(
    code: 'FA219',
    message: 'A situação do terminal é inválida.',
    action: 'Atualize o sistema e tente novamente.',
    retryable: false,
  ),
  'FA220': ErrorCatalogEntry(
    code: 'FA220',
    message: 'Este aparelho já está cadastrado como terminal.',
    action: 'Consulte a lista de terminais na retaguarda.',
    retryable: false,
  ),
  'FA221': ErrorCatalogEntry(
    code: 'FA221',
    message: 'A chave de segurança do terminal é inválida.',
    action: 'Reinicie o cadastro do terminal.',
    retryable: false,
  ),
  'FA222': ErrorCatalogEntry(
    code: 'FA222',
    message: 'O usuário já está vinculado a esta filial.',
    action: 'Atualize a tela para ver os vínculos atuais.',
    retryable: false,
  ),
  'FA301': ErrorCatalogEntry(
    code: 'FA301',
    message: 'Código não encontrado ou expirado.',
    action: 'Confira o código na tela do terminal. Se expirou, o terminal mostra um novo.',
    retryable: false,
  ),
  'FA302': ErrorCatalogEntry(
    code: 'FA302',
    message: 'Informe o motivo desta ação.',
    action: 'Preencha o motivo e tente novamente.',
    retryable: false,
  ),
  'FA303': ErrorCatalogEntry(
    code: 'FA303',
    message: 'Esta mudança de situação não é permitida para o terminal.',
    action: 'Atualize a tela para ver a situação atual.',
    retryable: false,
  ),
  'FA304': ErrorCatalogEntry(
    code: 'FA304',
    message: 'Este terminal está bloqueado.',
    action: 'Procure o administrador da rede.',
    retryable: false,
  ),
  'FA305': ErrorCatalogEntry(
    code: 'FA305',
    message: 'Este terminal foi revogado.',
    action: 'Faça um novo cadastro do terminal.',
    retryable: false,
  ),
  'FA306': ErrorCatalogEntry(
    code: 'FA306',
    message: 'Não foi possível confirmar a identidade do terminal.',
    action: 'Reinicie o terminal. Se continuar, faça um novo cadastro.',
    retryable: false,
  ),
  'FA307': ErrorCatalogEntry(
    code: 'FA307',
    message: 'Este terminal ainda não foi aprovado.',
    action: 'Aguarde a aprovação na retaguarda.',
    retryable: true,
  ),
  'FA308': ErrorCatalogEntry(
    code: 'FA308',
    message: 'A chave de segurança do aparelho é inválida.',
    action: 'Reinicie o terminal e tente novamente.',
    retryable: false,
  ),
  'FA310': ErrorCatalogEntry(
    code: 'FA310',
    message: 'Os dados do terminal são inválidos.',
    action: 'Atualize o sistema e tente novamente.',
    retryable: false,
  ),
  'FA311': ErrorCatalogEntry(
    code: 'FA311',
    message: 'Esta filial atingiu o limite de terminais.',
    action: 'Fale com o suporte para reorganizar os terminais da filial.',
    retryable: false,
  ),
};
