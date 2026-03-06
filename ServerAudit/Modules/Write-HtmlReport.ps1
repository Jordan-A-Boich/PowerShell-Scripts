function Write-HtmlReport {

param(
    $Results,
    $ServerSummary,
    $OutputPath
)

# ---------------------------------------------
# HTML HEADER (styles + JavaScript)
# ---------------------------------------------

$htmlHeader = @"
<html>
<head>
<title>SQL Server Audit</title>

<style>

body{
    font-family:Arial;
    background:#f4f4f4;
}

h1{
    text-align:center;
}

table{
    border-collapse:collapse;
    width:100%;
}

th,td{
    border:1px solid #ccc;
    padding:6px;
}

th{
    background:#333;
    color:white;
}

.pass{background:#d4edda;}
.warning{background:#fff3cd;}
.critical{background:#f8d7da;}

.serverHeader{
    cursor:pointer;
    background:#222;
    color:white;
    font-weight:bold;
}

.hidden{
    display:none;
}

</style>

<script>

function toggleServer(server){

    var rows = document.getElementsByClassName(server);

    for(var i=0;i<rows.length;i++){

        if(rows[i].style.display === "none"){
            rows[i].style.display = "table-row";
        }
        else{
            rows[i].style.display = "none";
        }

    }

}

</script>

</head>
<body>

<h1>SQL Server Audit Report</h1>

<h2>Server Health</h2>

<table>
<tr>
<th>Server</th>
<th>Status</th>
</tr>
"@

# ---------------------------------------------
# SERVER HEALTH SUMMARY
# ---------------------------------------------

$htmlSummary = ""

foreach($server in $ServerSummary){

    $statusClass = $server.Status.ToLower()

    $htmlSummary += "<tr class='$statusClass'>"
    $htmlSummary += "<td>$($server.Server)</td>"
    $htmlSummary += "<td>$($server.Status)</td>"
    $htmlSummary += "</tr>"
}

$htmlSummary += "</table>"

# ---------------------------------------------
# DETAILED CHECKS (COLLAPSIBLE)
# ---------------------------------------------

$htmlBody = "<h2>Detailed Checks</h2>"
$htmlBody += "<table>"

# HEADER ROW
$htmlBody += @"
<tr>
<th>Server</th>
<th>Check</th>
<th>Status</th>
<th>Severity</th>
<th>Message</th>
<th>Details</th>
</tr>
"@

$groupedResults = $Results | Group-Object Server

foreach($server in $groupedResults){

    $serverId = $server.Name.Replace("\","_")

    $htmlBody += "<tr class='serverHeader' onclick=""toggleServer('$serverId')"">"
    $htmlBody += "<td colspan='6'>▶ $($server.Name)</td>"
    $htmlBody += "</tr>"

    foreach($check in $server.Group){

        $statusClass = $check.Status.ToLower()

        $htmlBody += "<tr class='$serverId hidden $statusClass'>"
        $htmlBody += "<td>$($check.Server)</td>"
        $htmlBody += "<td>$($check.Check)</td>"
        $htmlBody += "<td>$($check.Status)</td>"
        $htmlBody += "<td>$($check.Severity)</td>"
        $htmlBody += "<td>$($check.Message)</td>"
        $htmlBody += "<td>$($check.Details)</td>"
        $htmlBody += "</tr>"
    }

}

$htmlBody += "</table>"

# ---------------------------------------------
# HTML FOOTER
# ---------------------------------------------

$htmlFooter = @"
</body>
</html>
"@

# ---------------------------------------------
# WRITE REPORT
# ---------------------------------------------

$html = $htmlHeader + $htmlSummary + $htmlBody + $htmlFooter

$html | Out-File "$OutputPath\ServerAuditReport.html"

}