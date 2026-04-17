<script setup lang="ts">
import { ref, computed } from 'vue'
import { useWorkspacesStore } from '../stores/workspaces'

interface NavItem {
  id: string
  label: string
  icon: string
  active?: boolean
}

const emit = defineEmits<{
  navigate: [id: string]
}>()

const workspacesStore = useWorkspacesStore()

const navItems = ref<NavItem[]>([
  { id: 'chat', label: 'Chat', icon: '◈', active: true },
])

// Add workspace modal state
const showAddWorkspaceModal = ref(false)
const newWorkspaceName = ref('')
const newWorkspaceIcon = ref('📂')

const workspaceIcons = ['📂', '📁', '📋', '💼', '🎯', '🚀', '⚡', '🔧', '🎨', '📦']

const mainNavActive = computed(() => navItems.value.find((item) => item.active)?.id || 'chat')

const setActive = (id: string) => {
  navItems.value = navItems.value.map((item) => ({
    ...item,
    active: item.id === id,
  }))
  workspacesStore.setActiveWorkspaceItem(null)
  emit('navigate', id)
}

const handleWorkspaceItemClick = async (workspaceId: string, itemId: string) => {
  // Find the item
  const workspace = workspacesStore.workspaces.find((ws) => ws.id === workspaceId)
  const item = workspace?.items.find((i) => i.id === itemId)

  // If item has a path and hasn't been loaded, fetch contents
  if (item?.path && !item.isLoaded && !item.isLoading) {
    await workspacesStore.fetchFolderContents(workspaceId, itemId)
  }

  // Deactivate main nav items
  navItems.value = navItems.value.map((navItem) => ({
    ...navItem,
    active: false,
  }))
  // Set active workspace item
  workspacesStore.setActiveWorkspaceItem(itemId)
  emit('navigate', 'workspace')
}

// Toggle nested folder visibility
const toggleNestedFolder = async (workspaceId: string, itemId: string, event: Event) => {
  event.stopPropagation()

  const workspace = workspacesStore.workspaces.find((ws) => ws.id === workspaceId)
  const item = workspace?.items.find((i) => i.id === itemId)

  if (!item) return

  // If not loaded, fetch contents
  if (!item.isLoaded && !item.isLoading && item.path) {
    await workspacesStore.fetchFolderContents(workspaceId, itemId)
  }

  // Toggle expanded state
  item.expanded = !item.expanded
}

// Get icon for file/folder type
const getEntryIcon = (entry: { is_directory: boolean; is_symlink: boolean }) => {
  if (entry.is_symlink) return '🔗'
  if (entry.is_directory) return '📁'
  return '📄'
}

const openAddWorkspaceModal = () => {
  newWorkspaceName.value = ''
  newWorkspaceIcon.value = '📂'
  showAddWorkspaceModal.value = true
}

const closeAddWorkspaceModal = () => {
  showAddWorkspaceModal.value = false
}

const handleAddWorkspace = () => {
  if (newWorkspaceName.value.trim()) {
    workspacesStore.addWorkspace(newWorkspaceName.value.trim(), newWorkspaceIcon.value)
    closeAddWorkspaceModal()
  }
}

const handleAddItemToWorkspace = (workspaceId: string) => {
  const name = prompt('Enter project name:')
  if (name?.trim()) {
    workspacesStore.addWorkspaceItem(workspaceId, name.trim())
  }
}
</script>

<template>
  <aside
    class="w-72 h-screen flex flex-col"
    style="background-color: var(--semantic-sidebar-bg); border-right: 1px solid var(--semantic-sidebar-border);"
  >
    <!-- Logo Area -->
    <div
      class="h-16 flex items-center px-5 shrink-0"
      style="border-bottom: 1px solid var(--color-border);"
    >
      <div class="flex items-center gap-3">
        <div
          class="w-8 h-8 rounded-lg flex items-center justify-center"
          style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue));"
        >
          <span
            class="text-sm font-bold"
            style="color: var(--color-bg);"
          >N</span>
        </div>
        <span
          class="text-lg font-semibold tracking-tight"
          style="color: var(--semantic-text);"
        >Nalar</span>
      </div>
    </div>

    <!-- Navigation -->
    <nav class="flex-1 py-4 px-3 overflow-y-auto">
      <!-- Main Nav Items -->
      <ul class="space-y-1">
        <li v-for="item in navItems" :key="item.id">
          <button
            @click="setActive(item.id)"
            class="w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm font-medium transition-all duration-200 group"
            :style="item.active
              ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text);`
              : `color: var(--semantic-text-muted);`"
          >
            <span
              class="text-lg transition-transform duration-200"
              :style="!item.active ? 'opacity: 0.7;' : ''"
            >{{ item.icon }}</span>
            <span>{{ item.label }}</span>
            <span
              v-if="item.active"
              class="ml-auto w-1.5 h-1.5 rounded-full"
              style="background-color: var(--color-aqua);"
            />
          </button>
        </li>
      </ul>

      <!-- Divider -->
      <div
        class="my-4 h-px"
        style="background: linear-gradient(90deg, transparent, var(--color-border), transparent);"
      />

      <!-- Workspaces Section -->
      <div class="space-y-1">
        <!-- Section Header -->
        <div class="px-3 py-2 flex items-center justify-between">
          <span
            class="text-xs font-semibold uppercase tracking-wider"
            style="color: var(--semantic-text-dim);"
          >Workspaces</span>
          <button
            @click="openAddWorkspaceModal"
            class="w-5 h-5 rounded flex items-center justify-center transition-colors duration-200 hover:opacity-80"
            style="color: var(--semantic-text-dim);"
            title="Add Workspace"
          >
            <span class="text-sm">+</span>
          </button>
        </div>

        <!-- Workspace Groups -->
        <div v-for="workspace in workspacesStore.workspaces" :key="workspace.id" class="space-y-0.5">
          <!-- Workspace Header (Expandable) -->
          <button
            @click="workspacesStore.toggleWorkspace(workspace.id)"
            class="w-full flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-all duration-200"
            :style="{
              backgroundColor: workspacesStore.activeWorkspace?.id === workspace.id
                ? 'var(--semantic-active-bg)'
                : 'transparent',
              color: workspacesStore.activeWorkspace?.id === workspace.id
                ? 'var(--semantic-active-text)'
                : 'var(--semantic-text-muted)',
            }"
          >
            <!-- Expand/Collapse Icon -->
            <span
              class="text-xs transition-transform duration-200 w-4 flex justify-center"
              :style="{ transform: workspace.expanded ? 'rotate(90deg)' : 'rotate(0deg)' }"
            >▶</span>
            <!-- Workspace Icon -->
            <span class="text-base">{{ workspace.icon }}</span>
            <!-- Workspace Name -->
            <span class="flex-1 text-left font-medium truncate">{{ workspace.name }}</span>
            <!-- Item Count Badge -->
            <span
              v-if="workspace.items.length > 0"
              class="text-xs px-1.5 py-0.5 rounded-full"
              style="background-color: var(--color-bg-p1); color: var(--semantic-text-dim);"
            >
              {{ workspace.items.length }}
            </span>
          </button>

          <!-- Workspace Items (Collapsible) -->
          <Transition name="slide">
            <ul v-if="workspace.expanded" class="ml-4 pl-3 space-y-0.5 border-l" style="border-color: var(--color-border);">
              <li v-for="item in workspace.items" :key="item.id">
                <button
                  @click="handleWorkspaceItemClick(workspace.id, item.id)"
                  class="w-full flex items-center gap-2 px-3 py-1.5 rounded-md text-sm transition-all duration-200 group"
                  :style="workspacesStore.activeWorkspaceItemId === item.id
                    ? `background-color: var(--semantic-active-bg); color: var(--semantic-active-text);`
                    : `color: var(--semantic-text-muted);`"
                >
                  <!-- Item Icon -->
                  <span
                    class="text-xs transition-colors duration-200"
                    :style="workspacesStore.activeWorkspaceItemId === item.id
                      ? 'opacity: 1;'
                      : 'opacity: 0.5;'"
                  >{{ item.icon }}</span>
                  <!-- Item Name -->
                  <span class="truncate">{{ item.name }}</span>
                  <!-- Active Indicator -->
                  <span
                    v-if="workspacesStore.activeWorkspaceItemId === item.id"
                    class="ml-auto w-1.5 h-1.5 rounded-full"
                    style="background-color: var(--color-aqua);"
                  />
                </button>
              </li>
              <!-- Add Item Button -->
              <li>
                <button
                  @click="handleAddItemToWorkspace(workspace.id)"
                  class="w-full flex items-center gap-2 px-3 py-1.5 rounded-md text-sm transition-all duration-200 opacity-0 group-hover:opacity-100"
                  style="color: var(--semantic-text-dim);"
                >
                  <span class="text-xs">+</span>
                  <span class="truncate">Add Project</span>
                </button>
              </li>
            </ul>
          </Transition>
        </div>
      </div>
    </nav>

    <!-- Status / Footer -->
    <div
      class="p-4 shrink-0"
      style="border-top: 1px solid var(--color-border);"
    >
      <div class="flex items-center gap-3">
        <div
          class="w-9 h-9 rounded-full flex items-center justify-center text-sm font-medium"
          style="background: linear-gradient(135deg, var(--color-green), var(--color-aqua)); color: var(--color-bg);"
        >
          U
        </div>
        <div class="flex-1 min-w-0">
          <p
            class="text-sm font-medium truncate"
            style="color: var(--semantic-text);"
          >User</p>
          <p
            class="text-xs flex items-center gap-1"
            style="color: var(--semantic-text-muted);"
          >
            <span
              class="w-1.5 h-1.5 rounded-full"
              style="background-color: var(--semantic-success);"
            />
            Online
          </p>
        </div>
      </div>
    </div>

    <!-- Add Workspace Modal -->
    <Teleport to="body">
      <Transition name="modal">
        <div
          v-if="showAddWorkspaceModal"
          class="fixed inset-0 z-50 flex items-center justify-center"
          @click.self="closeAddWorkspaceModal"
        >
          <!-- Backdrop -->
          <div
            class="absolute inset-0 bg-black/60 backdrop-blur-sm"
            @click="closeAddWorkspaceModal"
          />

          <!-- Modal Content -->
          <div
            class="relative w-full max-w-sm mx-4 p-6 rounded-xl shadow-2xl"
            style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border);"
          >
            <!-- Header -->
            <h3
              class="text-lg font-semibold mb-4"
              style="color: var(--semantic-text);"
            >
              Create Workspace
            </h3>

            <!-- Icon Selector -->
            <div class="mb-4">
              <label
                class="block text-xs font-medium mb-2"
                style="color: var(--semantic-text-dim);"
              >
                Choose Icon
              </label>
              <div class="flex flex-wrap gap-2">
                <button
                  v-for="icon in workspaceIcons"
                  :key="icon"
                  @click="newWorkspaceIcon = icon"
                  class="w-10 h-10 rounded-lg flex items-center justify-center text-xl transition-all duration-200"
                  :style="{
                    backgroundColor: newWorkspaceIcon === icon ? 'var(--semantic-active-bg)' : 'transparent',
                    border: `1px solid ${newWorkspaceIcon === icon ? 'var(--color-aqua)' : 'var(--color-border)'}`,
                  }"
                >
                  {{ icon }}
                </button>
              </div>
            </div>

            <!-- Name Input -->
            <div class="mb-6">
              <label
                class="block text-xs font-medium mb-2"
                style="color: var(--semantic-text-dim);"
              >
                Workspace Name
              </label>
              <input
                v-model="newWorkspaceName"
                type="text"
                placeholder="My Workspace"
                class="w-full px-3 py-2 rounded-lg text-sm outline-none transition-all duration-200"
                style="
                  background-color: var(--semantic-sidebar-bg);
                  border: 1px solid var(--color-border);
                  color: var(--semantic-text);
                "
                @keyup.enter="handleAddWorkspace"
                ref="workspaceNameInput"
              />
            </div>

            <!-- Actions -->
            <div class="flex justify-end gap-3">
              <button
                @click="closeAddWorkspaceModal"
                class="px-4 py-2 rounded-lg text-sm font-medium transition-all duration-200"
                style="background-color: var(--semantic-sidebar-bg); color: var(--semantic-text-muted);"
              >
                Cancel
              </button>
              <button
                @click="handleAddWorkspace"
                :disabled="!newWorkspaceName.trim()"
                class="px-4 py-2 rounded-lg text-sm font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
                style="background: linear-gradient(135deg, var(--color-violet), var(--color-blue)); color: var(--color-bg);"
              >
                Create
              </button>
            </div>
          </div>
        </div>
      </Transition>
    </Teleport>
  </aside>
</template>

<style scoped>
/* Slide transition for workspace items */
.slide-enter-active,
.slide-leave-active {
  transition: all 0.2s ease-out;
  overflow: hidden;
}

.slide-enter-from,
.slide-leave-to {
  opacity: 0;
  max-height: 0;
  transform: translateY(-4px);
}

.slide-enter-to,
.slide-leave-from {
  opacity: 1;
  max-height: 500px;
}

/* Modal transitions */
.modal-enter-active,
.modal-leave-active {
  transition: all 0.25s ease-out;
}

.modal-enter-from,
.modal-leave-to {
  opacity: 0;
}

.modal-enter-from > div:last-child,
.modal-leave-to > div:last-child {
  transform: scale(0.95) translateY(10px);
}
</style>
