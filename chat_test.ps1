param(
  [string]$cid = "chat1",
  [string]$url = "http://127.0.0.1:6000/a2a"
)

Write-Host "Interactive chat. Type 'exit' to quit. Use '/cid NEWID' to switch conversation.`n"

while ($true) {
  $msg = Read-Host "You"
  if ($msg -eq "exit") { break }

  if ($msg -like "/cid *") {
    $cid = $msg.Split(" ",2)[1]
    Write-Host ("Conversation switched to: {0}`n" -f $cid)
    continue
  }

  $body = @{
    content = @{ text = $msg; type = "text" }
    role    = "user"
    conversation_id = $cid
  } | ConvertTo-Json

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $url -ContentType "application/json" -Body $body
    $text = $resp.content.text
    if (-not $text) { $text = ($resp | ConvertTo-Json -Depth 10) }
    Write-Host ""
    Write-Host "Agent: $text"
    Write-Host ""
  }
  catch {
    Write-Host ("Request failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
  }
}

Write-Host "Chat ended."
