defmodule ElixIRCd.Utils.Nickserv.Translation do
  @moduledoc "Translates NickServ replies while preserving IRC formatting and values."

  @translations %{
    "NickServ help:" => "Ajuda do NickServ:",
    "For more information on a command, type \x02/msg NickServ HELP <command>\x02" =>
      "Para mais informações sobre um comando, digite \x02/msg NickServ HELP <comando>\x02",
    "You must identify to NickServ before using the SET command." =>
      "Você precisa se identificar no NickServ antes de usar SET.",
    "You must identify to NickServ before using MEMO." => "Você precisa se identificar no NickServ antes de usar MEMO.",
    "You must identify to NickServ before using the GROUP command." =>
      "Você precisa se identificar no NickServ antes de usar GROUP.",
    "Use \x02/msg NickServ IDENTIFY <password>\x02 to identify." =>
      "Use \x02/msg NickServ IDENTIFY <senha>\x02 para se identificar.",
    "No custom properties are set." => "Nenhuma propriedade personalizada foi definida.",
    "No public key is configured." => "Nenhuma chave pública está configurada.",
    "Your NickServ memo inbox is empty." => "Sua caixa de memos do NickServ está vazia.",
    "End of memo list." => "Fim da lista de memos.",
    "End of list." => "Fim da lista.",
    "Registered nicknames:" => "Apelidos registrados:",
    "No registered nicknames matched your search." => "Nenhum apelido registrado corresponde à busca.",
    "An error occurred while updating your NickServ settings." =>
      "Ocorreu um erro ao atualizar suas configurações do NickServ.",
    "Your email address will now be hidden from \x02INFO\x02 displays." =>
      "Seu endereço de email agora ficará oculto nas consultas \x02INFO\x02.",
    "Your email address will now be shown in \x02INFO\x02 displays." =>
      "Seu endereço de email agora será exibido nas consultas \x02INFO\x02.",
    "Your email address has been removed from your account." => "Seu endereço de email foi removido da sua conta.",
    "That is already the email address on your account." => "Esse já é o endereço de email da sua conta.",
    "This server requires an email address for registered nicknames." =>
      "Este servidor exige um endereço de email para apelidos registrados.",
    "Invalid URL." => "URL inválida.",
    "Your account accepts email-only memos but has no email address configured." =>
      "Sua conta aceita apenas memos por email, mas não possui um endereço configurado.",
    "Memo is too long. The maximum length is 400 characters." =>
      "O memo é muito longo. O tamanho máximo é de 400 caracteres."
  }

  @doc "Returns a NickServ message in the requested language, falling back to English."
  @spec translate(String.t(), String.t() | nil) :: String.t()
  def translate(message, "pt-BR"), do: translate_pt(message)
  def translate(message, _language), do: message

  @spec translate_pt(String.t()) :: String.t()
  defp translate_pt(message), do: Map.get(@translations, message) || translate_dynamic(message)

  @spec translate_dynamic(String.t()) :: String.t()
  defp translate_dynamic(message) do
    [
      {~r/\AInsufficient parameters for \x02([^\x02]+)\x02\.$/, &translate_insufficient/1},
      {~r/\ASyntax: \x02(.+)\x02\z/, &translate_syntax/1},
      {~r/\AInvalid parameter for \x02([^\x02]+)\x02\.$/, &translate_invalid_parameter/1},
      {~r/\AYour \x02([^\x02]+)\x02 setting is now \x02([^\x02]+)\x02\.$/, &translate_setting/1},
      {~r/\AYour memo was (.+)\.$/, &translate_memo_result/1},
      {~r/\ADeleted (\d+) (memo|memos) from your inbox\.$/, &translate_deleted_memos/1},
      {~r/\AMemo \x02([^\x02]+)\x02 was not found in your inbox\.$/, &translate_missing_memo/1},
      {~r/\AMemo \x02([^\x02]+)\x02 has been deleted\.$/, &translate_deleted_memo/1},
      {~r/\A(?:Nick|Nickname) \x02([^\x02]+)\x02 is not registered\.$/, &translate_unregistered_nick/1},
      {~r/\AYou are now identified for \x02([^\x02]+)\x02\.$/, &translate_identified/1},
      {~r/\AYou are now logged out from \x02([^\x02]+)\x02\.$/, &translate_logged_out/1},
      {~r/\ANick \x02([^\x02]+)\x02 has been dropped\.$/, &translate_dropped_nick/1},
      {~r/\ANick \x02([^\x02]+)\x02 has been released\.$/, &translate_released_nick/1},
      {~r/\AUnknown SET option: \x02([^\x02]+)\x02\z/, &translate_unknown_set/1}
    ]
    |> Enum.find_value(fn {pattern, translator} -> translate_match(message, pattern, translator) end)
    |> case do
      nil -> message
      translated -> translated
    end
  end

  @spec translate_match(String.t(), Regex.t(), (list() -> String.t())) :: String.t() | nil
  defp translate_match(message, pattern, translator) do
    case Regex.run(pattern, message) do
      nil -> nil
      captures -> translator.(captures)
    end
  end

  defp translate_insufficient([_, option]), do: "Parâmetros insuficientes para #{bold(option)}."
  defp translate_syntax([_, syntax]), do: "Sintaxe: #{bold(syntax)}"
  defp translate_invalid_parameter([_, option]), do: "Parâmetro inválido para #{bold(option)}."
  defp translate_setting([_, option, value]), do: "A configuração #{bold(option)} agora está em #{bold(value)}."
  defp translate_memo_result([_, result]), do: "Seu memo #{result}."
  defp translate_deleted_memos([_, count, _plural]), do: "#{count} memo(s) foram excluídos da sua caixa de entrada."
  defp translate_missing_memo([_, id]), do: "O memo #{bold(id)} não foi encontrado na sua caixa de entrada."
  defp translate_deleted_memo([_, id]), do: "O memo #{bold(id)} foi excluído."
  defp translate_unregistered_nick([_, nickname]), do: "O apelido #{bold(nickname)} não está registrado."
  defp translate_identified([_, account]), do: "Você agora está identificado para #{bold(account)}."
  defp translate_logged_out([_, account]), do: "Você saiu da conta #{bold(account)}."
  defp translate_dropped_nick([_, nickname]), do: "O apelido #{bold(nickname)} foi removido."
  defp translate_released_nick([_, nickname]), do: "O apelido #{bold(nickname)} foi liberado."
  defp translate_unknown_set([_, option]), do: "Opção SET desconhecida: #{bold(option)}"

  @spec bold(String.t()) :: String.t()
  defp bold(value), do: <<2>> <> value <> <<2>>
end
