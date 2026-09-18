defmodule ElixIRCd.Utils.Nickserv.TranslationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElixIRCd.Utils.Nickserv.Translation

  test "translates exact NickServ messages to Brazilian Portuguese" do
    assert Translation.translate("NickServ help:", "pt-BR") == "Ajuda do NickServ:"
    assert Translation.translate("End of list.", "pt-BR") == "Fim da lista."
  end

  test "preserves IRC bold formatting and dynamic values" do
    message = "Your \x02HIDEMAIL\x02 setting is now \x02ON\x02."

    assert Translation.translate(message, "pt-BR") ==
             "A configuração \x02HIDEMAIL\x02 agora está em \x02ON\x02."
  end

  test "translates the complete NickServ SET, LIST, and MEMO vocabulary" do
    messages = [
      {"For more information on a command, type \x02/msg NickServ HELP <command>\x02",
       "Para mais informações sobre um comando, digite \x02/msg NickServ HELP <comando>\x02"},
      {"You must identify to NickServ before using the SET command.",
       "Você precisa se identificar no NickServ antes de usar SET."},
      {"You must identify to NickServ before using MEMO.",
       "Você precisa se identificar no NickServ antes de usar MEMO."},
      {"You must identify to NickServ before using the GROUP command.",
       "Você precisa se identificar no NickServ antes de usar GROUP."},
      {"Use \x02/msg NickServ IDENTIFY <password>\x02 to identify.",
       "Use \x02/msg NickServ IDENTIFY <senha>\x02 para se identificar."},
      {"No custom properties are set.", "Nenhuma propriedade personalizada foi definida."},
      {"No public key is configured.", "Nenhuma chave pública está configurada."},
      {"Your NickServ memo inbox is empty.", "Sua caixa de memos do NickServ está vazia."},
      {"End of memo list.", "Fim da lista de memos."},
      {"Registered nicknames:", "Apelidos registrados:"},
      {"No registered nicknames matched your search.", "Nenhum apelido registrado corresponde à busca."},
      {"An error occurred while updating your NickServ settings.",
       "Ocorreu um erro ao atualizar suas configurações do NickServ."},
      {"Your email address will now be hidden from \x02INFO\x02 displays.",
       "Seu endereço de email agora ficará oculto nas consultas \x02INFO\x02."},
      {"Your email address will now be shown in \x02INFO\x02 displays.",
       "Seu endereço de email agora será exibido nas consultas \x02INFO\x02."},
      {"Your email address has been removed from your account.", "Seu endereço de email foi removido da sua conta."},
      {"That is already the email address on your account.", "Esse já é o endereço de email da sua conta."},
      {"This server requires an email address for registered nicknames.",
       "Este servidor exige um endereço de email para apelidos registrados."},
      {"Invalid URL.", "URL inválida."},
      {"Your account accepts email-only memos but has no email address configured.",
       "Sua conta aceita apenas memos por email, mas não possui um endereço configurado."},
      {"Memo is too long. The maximum length is 400 characters.",
       "O memo é muito longo. O tamanho máximo é de 400 caracteres."}
    ]

    for {english, portuguese} <- messages do
      assert Translation.translate(english, "pt-BR") == portuguese
    end
  end

  test "translates dynamic NickServ replies" do
    messages = [
      "Insufficient parameters for \x02SET\x02.",
      "Syntax: \x02SET URL <url>\x02",
      "Invalid parameter for \x02LANGUAGE\x02.",
      "Your \x02SECURE\x02 setting is now \x02ON\x02.",
      "Your memo was stored and queued for email delivery.",
      "Deleted 1 memo from your inbox.",
      "Deleted 2 memos from your inbox.",
      "Memo \x02memo-id\x02 was not found in your inbox.",
      "Memo \x02memo-id\x02 has been deleted.",
      "Nick \x02SomeNick\x02 is not registered.",
      "Nickname \x02SomeNick\x02 is not registered.",
      "You are now identified for \x02Account\x02.",
      "You are now logged out from \x02Account\x02.",
      "Nick \x02SomeNick\x02 has been dropped.",
      "Nick \x02SomeNick\x02 has been released.",
      "Unknown SET option: \x02UNKNOWN\x02"
    ]

    for message <- messages do
      translated = Translation.translate(message, "pt-BR")
      refute translated == message
    end
  end

  test "falls back to the original message for unsupported languages or text" do
    message = "A message without a translation"

    assert Translation.translate(message, "en") == message
    assert Translation.translate(message, nil) == message
  end
end
