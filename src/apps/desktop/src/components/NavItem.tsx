import type { Component, JSX } from "solid-js";

interface NavItemProps {
  label: string;
  href: string;
  icon: JSX.Element;
}

const NavItem: Component<NavItemProps> = (props) => {
  return (
    <li>
      <a
        href={props.href}
        class="flex items-center gap-3 px-4 py-2.5 text-sm text-[#737373] border-l-2 border-transparent hover:bg-[#141414] hover:text-[#e5e5e5] hover:border-[#facc15] transition-all duration-150"
      >
        <span class="flex-shrink-0">{props.icon}</span>
        <span class="font-medium">{props.label}</span>
      </a>
    </li>
  );
};

export default NavItem;
