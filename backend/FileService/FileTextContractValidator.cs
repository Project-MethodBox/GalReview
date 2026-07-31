public static class FileTextContractValidator
{
    public static void Validate(ExtractionResult extraction)
    {
        ArgumentNullException.ThrowIfNull(extraction);
        if (string.IsNullOrWhiteSpace(extraction.Text) ||
            extraction.SourceMap.Count == 0 ||
            extraction.Blocks.Count == 0)
        {
            throw new InvalidOperationException(
                "No contract-valid extractable text was found.");
        }

        long previousEnd = 0;
        foreach (var source in extraction.SourceMap)
        {
            if (source.StartOffset < previousEnd ||
                source.EndOffset <= source.StartOffset ||
                source.EndOffset > extraction.Text.Length)
            {
                throw new InvalidOperationException(
                    "The extracted source map is invalid.");
            }

            previousEnd = source.EndOffset;
        }

        foreach (var block in extraction.Blocks)
        {
            var source = block.Source;
            if (source.StartOffset < 0 ||
                source.EndOffset <= source.StartOffset ||
                source.EndOffset > extraction.Text.Length ||
                block.Text != extraction.Text.Substring(
                    (int)source.StartOffset,
                    (int)(source.EndOffset - source.StartOffset)))
            {
                throw new InvalidOperationException(
                    "An extracted text block is invalid.");
            }
        }
    }
}
