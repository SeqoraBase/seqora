"use client";

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <div className="min-h-screen bg-base flex items-center justify-center">
      <div className="text-center space-y-4">
        <h2 className="text-xl font-semibold text-text-primary">
          Something went wrong
        </h2>
        <p className="text-text-tertiary text-sm max-w-md">
          {error.message || "Failed to load registry data."}
        </p>
        <button
          onClick={reset}
          className="rounded-lg bg-primary px-4 py-2 text-sm font-medium transition-colors hover:bg-primary-hover"
          style={{ color: "#0A0B0F" }}
        >
          Try again
        </button>
      </div>
    </div>
  );
}
