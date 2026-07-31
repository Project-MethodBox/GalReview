using System.Text.RegularExpressions;

public static class UserProfileValidation
{
    private static readonly Regex SubjectCodePattern =
        new("^[A-Z][A-Z0-9_]{0,31}$", RegexOptions.CultureInvariant);

    public static bool IsValidDisplayName(string? value) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Trim().Length is >= 1 and <= 64;

    public static bool IsValidLocale(string value) =>
        value.Length is > 1 and <= 16 &&
        value.All(character =>
            char.IsLetterOrDigit(character) ||
            character is '-' or '_');

    public static bool IsValid(UpdateUserProfileRequest? request) =>
        request is not null &&
        (request.DisplayName is null ||
         IsValidDisplayName(request.DisplayName)) &&
        (request.Locale is null ||
         IsValidLocale(request.Locale)) &&
        (request.PreferredSubjectCodes is null ||
         request.PreferredSubjectCodes.Length <= 10 &&
         request.PreferredSubjectCodes.All(
             code =>
                 !string.IsNullOrWhiteSpace(code) &&
                 SubjectCodePattern.IsMatch(
                     code.Trim().ToUpperInvariant())));

    public static UpdateUserProfileRequest Normalize(
        UpdateUserProfileRequest request) =>
        request with
        {
            PreferredSubjectCodes =
                request.PreferredSubjectCodes?
                    .Select(code => code.Trim().ToUpperInvariant())
                    .ToArray()
        };
}
