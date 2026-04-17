import { clsx } from "@/lib/clsx";

type ContainerProps = React.HTMLAttributes<HTMLDivElement> & {
  as?: "div" | "section" | "article" | "header" | "footer" | "main";
  width?: "prose" | "default" | "wide";
};

const widthMap = {
  prose: "max-w-[68ch]",
  default: "max-w-[1120px]",
  wide: "max-w-[1320px]",
} as const;

export function Container({
  as: Tag = "div",
  width = "default",
  className,
  children,
  ...rest
}: ContainerProps) {
  return (
    <Tag
      {...rest}
      className={clsx(
        "mx-auto w-full px-6 md:px-8",
        widthMap[width],
        className,
      )}
    >
      {children}
    </Tag>
  );
}
