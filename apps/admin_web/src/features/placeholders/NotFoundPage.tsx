import { Card, EmptyState } from '../../components/common/ui'

export function NotFoundPage() {
  return (
    <Card>
      <EmptyState title="Page not found" message="That address does not exist in the admin console." />
    </Card>
  )
}
