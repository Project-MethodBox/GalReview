[CmdletBinding()]
param(
    [Security.SecureString]$Password
)

$ErrorActionPreference = 'Stop'
if ($null -eq $Password) {
    $Password = Read-Host 'Enter the administrator password to hash' -AsSecureString
}

$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
$plainText = $null
try {
    $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    if ([string]::IsNullOrWhiteSpace($plainText)) {
        throw 'The administrator password cannot be empty.'
    }

    # ASP.NET Core Identity V3 format:
    # marker(1), PRF=HMACSHA512(4), iterations(4), salt length(4), salt, subkey.
    $salt = [Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
    $subkey = [Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2(
        $plainText,
        $salt,
        100000,
        [Security.Cryptography.HashAlgorithmName]::SHA512,
        32)
    $result = [byte[]]::new(61)
    $result[0] = 1

    function Write-UInt32BigEndian([byte[]]$Buffer, [int]$Offset, [uint32]$Value) {
        $Buffer[$Offset] = [byte](($Value -shr 24) -band 0xff)
        $Buffer[$Offset + 1] = [byte](($Value -shr 16) -band 0xff)
        $Buffer[$Offset + 2] = [byte](($Value -shr 8) -band 0xff)
        $Buffer[$Offset + 3] = [byte]($Value -band 0xff)
    }

    Write-UInt32BigEndian $result 1 2
    Write-UInt32BigEndian $result 5 100000
    Write-UInt32BigEndian $result 9 16
    [Array]::Copy($salt, 0, $result, 13, $salt.Length)
    [Array]::Copy($subkey, 0, $result, 13 + $salt.Length, $subkey.Length)
    [Convert]::ToBase64String($result)
}
finally {
    if ($null -ne $plainText) { $plainText = $null }
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
}
